import Foundation

enum CodexClientError: LocalizedError {
    case invalidResponse(String)
    case authenticationRequired
    case httpStatus(Int)
    case rpc(String)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let reason): return "Codex 返回了无法识别的数据：\(reason)"
        case .authenticationRequired: return "Codex 需要登录。请在服务器编辑页填写用户名和密码，或填写 WebSocket 令牌。"
        case .httpStatus(let status): return "Codex 登录失败（HTTP \(status)）。"
        case .rpc(let message): return message
        case .disconnected: return "Codex 实时连接已断开。"
        }
    }
}

struct CodexRPCNotification: Sendable {
    let method: String
    let params: JSONValue
}

enum CodexRPCClientEvent: Sendable {
    case notification(CodexRPCNotification)
    case failure(String)
}

enum CodexServerRequestKind: Sendable {
    case commandApproval
    case fileChangeApproval
    case permissionsApproval
    case userInput
}

struct CodexServerRequest: Sendable {
    let id: JSONValue
    let method: String
    let params: JSONValue

    var kind: CodexServerRequestKind? {
        switch method {
        case "item/commandExecution/requestApproval":
            return .commandApproval
        case "item/fileChange/requestApproval":
            return .fileChangeApproval
        case "item/permissions/requestApproval":
            return .permissionsApproval
        case "item/tool/requestUserInput":
            return .userInput
        default:
            return nil
        }
    }

    var idKey: String {
        requestIDKey(id)
    }
}

actor CodexRPCClient {
    typealias ServerRequestHandler = @Sendable (CodexServerRequest) -> JSONValue?

    private let profile: ServerProfile
    private let username: String
    private let password: String
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var nextRequestID = 0
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var eventContinuations: [UUID: AsyncThrowingStream<CodexRPCClientEvent, Error>.Continuation] = [:]
    private let serverRequestHandlerState = UnsafeSendableBox<ServerRequestHandler?>(nil)

    init(profile: ServerProfile, password: String) {
        self.profile = profile
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
            finishAll(with: CodexClientError.disconnected)
        }
        guard socket == nil else { return }

        let auth = try await authenticate()
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        guard let url = components?.url else { throw CodexClientError.invalidResponse("WebSocket 地址无效") }

        var request = URLRequest(url: url)
        if let bearer = auth.bearer, !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            request.setValue(bearer, forHTTPHeaderField: "Capability-Token")
        }
        if let cookieHeader = sessionCookieHeader() {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()
        receiveTask = Task { await receiveLoop(task) }
        startPing(task)

        _ = try await call(method: "initialize", params: [
            "clientInfo": .object([
                "name": .string("dsh-ios"),
                "version": .string("1.0")
            ])
        ])
    }

    func call(method: String, params: JSONValue) async throws -> JSONValue {
        try await connect()
        guard let socket else { throw CodexClientError.disconnected }
        nextRequestID += 1
        let requestID = "ios-\(nextRequestID)"
        let frame: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .string(requestID),
            "method": .string(method),
            "params": params
        ])
        let data = try JSONEncoder().encode(frame)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexClientError.invalidResponse("无法编码 RPC 请求")
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

    func call(method: String, params: [String: JSONValue]) async throws -> JSONValue {
        try await call(method: method, params: .object(params))
    }

    func respondToServerRequest(id: JSONValue, result: JSONValue) {
        guard let socket else { return }
        let frame: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": result
        ])
        guard let data = try? JSONEncoder().encode(frame),
              let text = String(data: data, encoding: .utf8) else { return }
        Task {
            try? await socket.send(.string(text))
        }
    }

    nonisolated func setServerRequestHandler(_ handler: @escaping ServerRequestHandler) {
        serverRequestHandlerState.value = handler
    }

    func events() -> AsyncThrowingStream<CodexRPCClientEvent, Error> {
        let id = UUID()
        return AsyncThrowingStream { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeEventContinuation(id) }
            }
        }
    }

    func close() {
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        finishAll(with: CodexClientError.disconnected)
    }

    private var baseURL: URL {
        profile.baseURL
    }

    private func sessionCookieHeader() -> String? {
        let cookies = HTTPCookieStorage.shared.cookies(for: baseURL) ?? []
        guard !cookies.isEmpty else { return nil }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private func authenticate() async throws -> CodexAuthResult {
        if !username.isEmpty, !password.isEmpty {
            if try await loginWithCookies() {
                return CodexAuthResult(bearer: nil)
            }
            // 用户名已填写但登录失败时不再回退成 Bearer Token，
            // 避免把密码误发到反代上产生模糊的断连错误。
            throw CodexClientError.authenticationRequired
        }
        return CodexAuthResult(bearer: password)
    }

    private func loginWithCookies() async throws -> Bool {
        let attempts: [(String, String)] = [
            ("/login", "basic"),
            ("/login", "json"),
            ("/api/login", "json"),
            ("/auth/login", "json"),
            ("/login", "form")
        ]
        for (path, encoding) in attempts {
            if try await attemptLogin(path: path, encoding: encoding) {
                return true
            }
        }
        return false
    }

    private func attemptLogin(path: String, encoding: String) async throws -> Bool {
        var request = URLRequest(url: endpoint(path))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: Data
        switch encoding {
        case "basic":
            let credential = Data("\(username):\(password)".utf8).base64EncodedString()
            request.httpMethod = "GET"
            request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
            body = Data()
        case "form":
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var items = URLComponents()
            items.queryItems = [
                URLQueryItem(name: "username", value: username),
                URLQueryItem(name: "password", value: password)
            ]
            body = items.query?.data(using: .utf8) ?? Data()
        default:
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let value: JSONValue = .object([
                "username": .string(username),
                "password": .string(password)
            ])
            body = try JSONEncoder().encode(value)
        }
        request.httpBody = body

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }
        guard (200..<300).contains(http.statusCode) else { return false }
        let hasCookie = (http.allHeaderFields["Set-Cookie"] as? String)?.isEmpty == false
            || (http.value(forHTTPHeaderField: "Set-Cookie")?.isEmpty == false)
        return hasCookie || http.statusCode == 200
    }

    private func endpoint(_ path: String) -> URL {
        path.split(separator: "/").reduce(baseURL) { url, part in
            url.appendingPathComponent(String(part))
        }
    }

    private func startPing(_ task: URLSessionWebSocketTask) {
        pingTask?.cancel()
        pingTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                    task.sendPing { _ in }
                } catch {
                    return
                }
            }
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
            for continuation in eventContinuations.values {
                continuation.yield(.failure(error.localizedDescription))
            }
            finishAll(with: error)
        }
    }

    private func handleFrame(_ frame: JSONValue) throws {
        if let requestID = frame["id"]?.stringValue, let continuation = pending.removeValue(forKey: requestID) {
            if let message = frame["error"]?["message"]?.stringValue {
                continuation.resume(throwing: CodexClientError.rpc(message))
            } else {
                continuation.resume(returning: frame["result"] ?? .null)
            }
            return
        }

        if frame["method"]?.stringValue != nil, frame["id"] != nil {
            let request = CodexServerRequest(
                id: frame["id"] ?? .null,
                method: frame["method"]?.stringValue ?? "",
                params: frame["params"] ?? .object([:])
            )
            if let handler = serverRequestHandlerState.value {
                if let result = handler(request) {
                    respondToServerRequest(id: request.id, result: result)
                }
            }
            return
        }

        guard let method = frame["method"]?.stringValue,
              let params = frame["params"] else { return }
        let event = CodexRPCNotification(method: method, params: params)
        for continuation in eventContinuations.values { continuation.yield(.notification(event)) }
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

private struct CodexAuthResult: Sendable {
    let bearer: String?
}

private func requestIDKey(_ value: JSONValue) -> String {
    if let string = value.stringValue { return string }
    if let number = value.doubleValue { return String(format: "%.0f", number) }
    return "null"
}

private final class UnsafeSendableBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
