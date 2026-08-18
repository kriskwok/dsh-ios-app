import Foundation

struct HermesGatewayEvent: Sendable {
    let type: String
    let sessionID: String?
    let payload: JSONValue
}

enum HermesClientError: LocalizedError {
    case invalidResponse(String)
    case authenticationRequired
    case httpStatus(Int)
    case rpc(String)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let reason): return "Hermes 返回了无法识别的数据：\(reason)"
        case .authenticationRequired: return "Hermes 需要登录。请完成系统登录页，或检查旧版服务器的用户名和密码。"
        case .httpStatus(let status): return "Hermes 连接失败（HTTP \(status)）。"
        case .rpc(let message): return message
        case .disconnected: return "Hermes 实时连接已断开。"
        }
    }
}

actor HermesRPCClient {
    private let profileID: UUID
    private let baseURL: URL
    private let username: String
    private let password: String
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var nextRequestID = 0
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var eventContinuations: [UUID: AsyncThrowingStream<HermesGatewayEvent, Error>.Continuation] = [:]

    init(profile: ServerProfile, password: String) {
        profileID = profile.id
        baseURL = profile.baseURL
        username = profile.username
        self.password = password
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpCookieStorage = .shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        session = URLSession(configuration: configuration)
    }

    func connect() async throws {
        if let socket, socket.state != .running {
            self.socket = nil
            receiveTask?.cancel()
            receiveTask = nil
            finishAll(with: HermesClientError.disconnected)
        }
        guard socket == nil else { return }
        let ticket = try await mintTicket()
        var components = URLComponents(url: endpoint("api/ws"), resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components?.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        guard let url = components?.url else { throw HermesClientError.invalidResponse("WebSocket 地址无效") }

        let task = session.webSocketTask(with: url)
        socket = task
        task.resume()
        receiveTask = Task { await receiveLoop(task) }
    }

    func call(method: String, params: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await connect()
        guard let socket else { throw HermesClientError.disconnected }
        nextRequestID += 1
        let requestID = "ios-\(nextRequestID)"
        let frame: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .string(requestID),
            "method": .string(method),
            "params": .object(params)
        ])
        let data = try JSONEncoder().encode(frame)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HermesClientError.invalidResponse("无法编码 RPC 请求")
        }

        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            Task {
                do {
                    try await socket.send(.string(text))
                } catch {
                    self.failRequest(requestID, error: error)
                }
            }
        }
    }

    func events() -> AsyncThrowingStream<HermesGatewayEvent, Error> {
        let id = UUID()
        return AsyncThrowingStream { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeEventContinuation(id) }
            }
        }
    }

    func close() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        finishAll(with: HermesClientError.disconnected)
    }

    private func mintTicket() async throws -> String {
        do {
            return try await requestTicket()
        } catch HermesClientError.httpStatus(let status) where status == 401 || status == 403 {
            let authStatus = try await fetchAuthStatus()
            if authStatus.supportsNativePKCE {
                let token = try await nativeAccessToken(provider: authStatus.nativeProvider)
                do {
                    return try await requestTicket(bearerToken: token)
                } catch HermesClientError.httpStatus(let retryStatus) where retryStatus == 401 || retryStatus == 403 {
                    await HermesNativeAuth.shared.invalidate(profileID: profileID)
                    let renewed = try await nativeAccessToken(provider: authStatus.nativeProvider)
                    return try await requestTicket(bearerToken: renewed)
                }
            } else {
                try await login()
                return try await requestTicket()
            }
        } catch HermesClientError.invalidResponse {
            try await login()
            return try await requestTicket()
        }
    }

    private func nativeAccessToken(provider: String?) async throws -> String {
        try await HermesNativeAuth.shared.validAccessToken(
            profileID: profileID,
            baseURL: baseURL,
            provider: provider,
            urlSession: session
        )
    }

    private func fetchAuthStatus() async throws -> HermesAuthStatus {
        let (data, response) = try await session.data(from: endpoint("api/status"))
        guard let http = response as? HTTPURLResponse else {
            throw HermesClientError.invalidResponse("状态请求没有 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else { throw HermesClientError.httpStatus(http.statusCode) }
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return HermesAuthStatus(value: value)
    }

    private func login() async throws {
        guard !username.isEmpty, !password.isEmpty else {
            throw HermesClientError.authenticationRequired
        }
        let body: JSONValue = .object([
            "provider": .string("basic"),
            "username": .string(username),
            "password": .string(password),
            "next": .string("/")
        ])
        var request = URLRequest(url: endpoint("auth/password-login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesClientError.invalidResponse("登录没有 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw http.statusCode == 401 ? HermesClientError.authenticationRequired : HermesClientError.httpStatus(http.statusCode)
        }
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw HermesClientError.invalidResponse("登录响应不是 JSON")
        }
        guard value["ok"]?.boolValue == true else { throw HermesClientError.authenticationRequired }
    }

    private func requestTicket(bearerToken: String? = nil) async throws -> String {
        var request = URLRequest(url: endpoint("api/auth/ws-ticket"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesClientError.invalidResponse("凭证请求没有 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else { throw HermesClientError.httpStatus(http.statusCode) }
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw HermesClientError.invalidResponse("凭证响应不是 JSON")
        }
        guard let ticket = value["ticket"]?.stringValue, !ticket.isEmpty else {
            throw HermesClientError.invalidResponse("缺少 WebSocket ticket")
        }
        return ticket
    }

    private func endpoint(_ path: String) -> URL {
        path.split(separator: "/").reduce(baseURL) { url, part in
            url.appendingPathComponent(String(part))
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let value): data = value
                @unknown default: continue
                }
                try handleFrame(JSONDecoder().decode(JSONValue.self, from: data))
            }
        } catch {
            guard !Task.isCancelled else { return }
            socket = nil
            finishAll(with: error)
        }
    }

    private func handleFrame(_ frame: JSONValue) throws {
        if let requestID = frame["id"]?.stringValue, let continuation = pending.removeValue(forKey: requestID) {
            if let message = frame["error"]?["message"]?.stringValue {
                continuation.resume(throwing: HermesClientError.rpc(message))
            } else {
                continuation.resume(returning: frame["result"] ?? .null)
            }
            return
        }
        guard frame["method"]?.stringValue == "event",
              let params = frame["params"],
              let type = params["type"]?.stringValue else { return }
        let event = HermesGatewayEvent(
            type: type,
            sessionID: params["session_id"]?.stringValue,
            payload: params["payload"] ?? .object([:])
        )
        for continuation in eventContinuations.values { continuation.yield(event) }
    }

    private func failRequest(_ id: String, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func finishAll(with error: Error) {
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending.removeAll()
        for continuation in eventContinuations.values { continuation.finish(throwing: error) }
        eventContinuations.removeAll()
    }
}

struct HermesAuthStatus: Equatable {
    let authFlows: [String]
    let authProviders: [String]

    init(value: JSONValue) {
        authFlows = value["auth_flows"]?.arrayValue?.compactMap(\.stringValue) ?? []
        authProviders = value["auth_providers"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    var supportsNativePKCE: Bool { authFlows.contains("native_pkce") }
    var nativeProvider: String? { authProviders.first { $0 != "basic" } }
}
