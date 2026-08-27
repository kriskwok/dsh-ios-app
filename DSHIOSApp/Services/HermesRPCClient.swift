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

    func httpGet(_ path: String, query: [String: String] = [:]) async throws -> JSONValue {
        var url = endpoint(path)
        if !query.isEmpty {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            url = components?.url ?? url
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesClientError.invalidResponse("HTTP 请求没有 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HermesClientError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func httpPut(_ path: String, body: JSONValue) async throws -> JSONValue {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesClientError.invalidResponse("HTTP 请求没有 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HermesClientError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func httpPost(_ path: String, body: JSONValue) async throws -> JSONValue {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesClientError.invalidResponse("HTTP 请求没有 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HermesClientError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Upload files via multipart/form-data to the hermes-web-ui `/upload`
    /// Upload files to Hermes Studio's `/upload` endpoint (port 8649).
    /// The agent API (8650) does not expose a general HTTP upload endpoint
    /// (only `/v1/artifacts/upload` for browser-control artifacts). Hermes
    /// Studio uses cookie-based session auth, so we log in via `/api/auth/login`
    /// first, then upload with the session cookie.
    func uploadFiles(_ files: [(name: String, data: Data, mimeType: String)]) async throws -> JSONValue {
        // Ensure WebSocket connection is established (also triggers auth flow).
        try await connect()

        // Log in to Hermes Studio (8649) to obtain a JWT token.
        guard !username.isEmpty && !password.isEmpty else {
            throw HermesClientError.invalidResponse("上传文件需要 Hermes Studio 登录凭据（用户名/密码），请在服务器配置中填写")
        }
        let studioToken = try await loginToStudio()

        // Hermes Studio upload endpoint: same host, port 8649.
        let uploadURL = hermesStudioUploadEndpoint()
        print("[HermesUpload] endpoint=\(uploadURL.absoluteString) files=\(files.map { $0.name })")

        // Upload each file individually (field name is `file`, singular).
        var registered: [JSONValue] = []
        for file in files {
            let result = try await uploadSingleFile(
                name: file.name,
                data: file.data,
                mimeType: file.mimeType,
                to: uploadURL,
                bearerToken: studioToken
            )
            if case .object(let dict) = result,
               case .array(let fileList) = dict["files"] {
                registered.append(contentsOf: fileList)
            }
        }
        return .object(["files": .array(registered)])
    }

    /// Log in to Hermes Studio (port 8649) via `/api/auth/login`.
    /// Returns the JWT access token from the response body.
    private func loginToStudio() async throws -> String {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.port = 8649
        components?.path = "/api/auth/login"
        guard let loginURL = components?.url else {
            throw HermesClientError.invalidResponse("无法构建 Hermes Studio 登录 URL")
        }

        let body: JSONValue = .object([
            "username": .string(username),
            "password": .string(password),
        ])

        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        print("[HermesUpload] logging in to studio: \(loginURL.absoluteString)")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesClientError.invalidResponse("Hermes Studio 登录没有 HTTP 响应")
        }

        let preview = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
        print("[HermesUpload] studio login status=\(http.statusCode) body=\(preview.prefix(120))")

        guard (200..<300).contains(http.statusCode) else {
            throw HermesClientError.authenticationRequired
        }

        // Parse JWT token from response body: {"token":"...", ...}
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let token = value["token"]?.stringValue, !token.isEmpty else {
            throw HermesClientError.invalidResponse("Hermes Studio 登录响应中没有 token")
        }
        print("[HermesUpload] got studio JWT token (length=\(token.count))")
        return token
    }

    private func uploadSingleFile(
        name: String,
        data: Data,
        mimeType: String,
        to url: URL,
        bearerToken: String
    ) async throws -> JSONValue {
        let boundary = "----hermes-ios-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        print("[HermesUpload] POST \(url.absoluteString) file=\(name) size=\(data.count)")

        let (respData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesClientError.invalidResponse("上传请求没有 HTTP 响应")
        }
        let contentType = http.allHeaderFields["Content-Type"] as? String ?? "unknown"
        let preview = String(data: respData.prefix(500), encoding: .utf8) ?? "<binary>"
        print("[HermesUpload] status=\(http.statusCode) contentType=\(contentType) body=\(preview)")

        guard (200..<300).contains(http.statusCode) else {
            throw HermesClientError.httpStatus(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(JSONValue.self, from: respData)
        } catch {
            print("[HermesUpload] JSON decode failed: \(error)")
            throw HermesClientError.invalidResponse("上传接口返回了非 JSON 数据（status=\(http.statusCode), type=\(contentType)）：\(preview)")
        }
    }

    /// Hermes Studio upload endpoint: same host as baseURL but on port 8649.
    private func hermesStudioUploadEndpoint() -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.port = 8649
        components?.path = "/upload"
        return components?.url ?? baseURL.appendingPathComponent("upload")
    }

    /// Cached Hermes Studio JWT token (avoids re-login on every file fetch).
    private var cachedStudioToken: String?

    /// Fetch file data from Hermes Studio by server-side path.
    /// Used to render images/files that were uploaded via Hermes Studio.
    func fetchFileData(path: String) async throws -> Data {
        // Reuse cached token if available; otherwise log in.
        let token: String
        if let cached = cachedStudioToken {
            token = cached
        } else {
            guard !username.isEmpty && !password.isEmpty else {
                throw HermesClientError.invalidResponse("获取文件需要 Hermes Studio 登录凭据")
            }
            token = try await loginToStudio()
            cachedStudioToken = token
        }

        // The /api/hermes/files/preview endpoint requires a path relative to
        // the profile data directory (e.g. "upload/default/xxx.png").
        // Uploaded files come back as absolute paths like
        // "/root/.hermes-web-ui/upload/default/xxx.png". Strip the data
        // directory prefix to get the relative path.
        let relativePath: String
        if let range = path.range(of: ".hermes-web-ui/") {
            relativePath = String(path[range.upperBound...])
        } else if path.hasPrefix("/") {
            // Fallback: strip leading slash and hope it resolves correctly.
            relativePath = String(path.dropFirst())
        } else {
            relativePath = path
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.port = 8649
        components?.path = "/api/hermes/files/preview"
        components?.queryItems = [URLQueryItem(name: "path", value: relativePath)]
        guard let url = components?.url else {
            throw HermesClientError.invalidResponse("无法构建文件读取 URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        print("[HermesFile] fetch path=\(path) relative=\(relativePath)")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesClientError.invalidResponse("文件读取没有 HTTP 响应")
        }

        let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
        print("[HermesFile] status=\(http.statusCode) contentType=\(http.value(forHTTPHeaderField: "Content-Type") ?? "n/a") size=\(data.count) body=\(preview.prefix(100))")

        // If token expired, clear cache and retry once.
        if http.statusCode == 401 {
            cachedStudioToken = nil
            let newToken = try await loginToStudio()
            cachedStudioToken = newToken
            request.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await session.data(for: request)
            guard let retryHttp = retryResponse as? HTTPURLResponse,
                  (200..<300).contains(retryHttp.statusCode) else {
                throw HermesClientError.httpStatus((retryResponse as? HTTPURLResponse)?.statusCode ?? 0)
            }
            print("[HermesFile] fetch success (retry) size=\(retryData.count)")
            return retryData
        }

        guard (200..<300).contains(http.statusCode) else {
            throw HermesClientError.httpStatus(http.statusCode)
        }
        print("[HermesFile] fetch success size=\(data.count)")
        return data
    }

    /// Extract raw file bytes from the `/api/hermes/files/read` response.
    /// The response may be raw binary or a JSON wrapper with base64/content.
    private func extractFileData(_ data: Data) throws -> Data {
        // Try to parse as JSON: {content: "...", encoding: "base64"} or similar.
        if let json = try? JSONDecoder().decode(JSONValue.self, from: data) {
            print("[HermesFile] JSON keys=\(json.objectValue?.keys.joined(separator: ",") ?? "n/a")")
            if let base64 = json["content"]?.stringValue ?? json["data"]?.stringValue,
               let decoded = Data(base64Encoded: base64) {
                print("[HermesFile] extracted from base64 content/data")
                return decoded
            }
            if let bytes = json["bytes"]?.arrayValue {
                print("[HermesFile] extracted from bytes array")
                return Data(bytes.compactMap { $0.intValue }.map { UInt8($0 & 0xFF) })
            }
            // If JSON has no recognizable data field, return raw data as-is.
            print("[HermesFile] JSON has no recognizable data field, returning raw")
        } else {
            print("[HermesFile] not JSON, returning raw binary size=\(data.count)")
        }
        return data
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
