import Foundation

private final class DSHSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let username: String
    private let password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    private func handle(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        let supported = method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest
        guard supported, challenge.previousFailureCount == 0 else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(user: username, password: password, persistence: .forSession))
    }
}

struct DSHCallResult: Sendable {
    let rpcId: String
    let value: JSONValue
}

final class DSHAPIClient: @unchecked Sendable {
    private let baseURL: URL
    private let username: String
    private let password: String
    private let delegate: DSHSessionDelegate
    private let session: URLSession

    init(profile: ServerProfile, password: String) {
        baseURL = profile.baseURL
        username = profile.username
        self.password = password
        delegate = DSHSessionDelegate(username: profile.username, password: password)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func call(
        method: String,
        payload: [String: JSONValue] = [:],
        rpcId: String = UUID().uuidString
    ) async throws -> DSHCallResult {
        let body: JSONValue = .object([
            "type": .string("client-request"),
            "rpcId": .string(rpcId),
            "method": .string(method),
            "payload": .object(payload)
        ])
        var request = authenticatedRequest(url: endpoint(method), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DSHClientError.invalidResponse("没有 HTTP 响应")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data.prefix(1_000), encoding: .utf8) ?? ""
            throw DSHClientError.httpStatus(httpResponse.statusCode, body)
        }

        let envelope = try JSONDecoder().decode(DSHRPCResponse.self, from: data)
        guard envelope.type == "server-response", envelope.rpcId == rpcId else {
            throw DSHClientError.invalidResponse("RPC 信封不匹配")
        }
        guard envelope.result.ok else {
            throw DSHClientError.server(envelope.result.error ?? DSHRPCError(
                code: "UNKNOWN",
                message: "DSH 请求失败",
                details: nil
            ))
        }
        return DSHCallResult(rpcId: rpcId, value: envelope.result.value ?? .null)
    }

    func respond(rpcId: String, value: [String: JSONValue]) async throws {
        let body: JSONValue = .object([
            "type": .string("client-response"),
            "rpcId": .string(rpcId),
            "result": .object([
                "ok": .bool(true),
                "value": .object(value)
            ])
        ])
        var request = authenticatedRequest(url: baseURL.appendingPathComponent("api/respond"), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DSHClientError.invalidResponse("审批没有 HTTP 响应")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data.prefix(1_000), encoding: .utf8) ?? ""
            throw DSHClientError.httpStatus(httpResponse.statusCode, body)
        }
        let receipt = try JSONDecoder().decode(DSHRPCReceipt.self, from: data)
        guard receipt.accepted else {
            throw DSHClientError.invalidResponse("审批未被接受：\(receipt.reason ?? "请求已失效")")
        }
    }

    func eventStream(path: String) -> AsyncThrowingStream<DSHServerRequest, Error> {
        let socket = session.webSocketTask(with: authenticatedRequest(url: webSocketEndpoint(path), method: "GET"))

        return AsyncThrowingStream { continuation in
            let receiver = Task {
                socket.resume()
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        let data: Data
                        switch message {
                        case .data(let value): data = value
                        case .string(let value): data = Data(value.utf8)
                        @unknown default: continue
                        }
                        continuation.yield(try JSONDecoder().decode(DSHServerRequest.self, from: data))
                    }
                    continuation.finish()
                } catch {
                    if !Task.isCancelled {
                        socket.cancel(with: .goingAway, reason: nil)
                        continuation.finish(throwing: error)
                    }
                }
            }

            let keepAlive = Task {
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(25))
                        try await Self.sendPing(on: socket)
                    }
                } catch {
                    if !Task.isCancelled {
                        socket.cancel(with: .goingAway, reason: nil)
                        continuation.finish(throwing: error)
                    }
                }
            }

            continuation.onTermination = { @Sendable _ in
                receiver.cancel()
                keepAlive.cancel()
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    private final class PingContinuationBox: @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Error>?
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }

        func resume(with error: Error?) {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            guard let cont else { return }
            if let error {
                cont.resume(throwing: error)
            } else {
                cont.resume()
            }
        }
    }

    private static func sendPing(on socket: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = PingContinuationBox(continuation)
            socket.sendPing { error in
                box.resume(with: error)
            }
        }
    }

    private func endpoint(_ method: String) -> URL {
        baseURL.appendingPathComponent("api").appendingPathComponent(method)
    }

    private func webSocketEndpoint(_ path: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        let prefix = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([prefix, "api", path].filter { !$0.isEmpty }.joined(separator: "/"))
        return components.url!
    }

    private func authenticatedRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !username.isEmpty {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
