import AuthenticationServices
import CryptoKit
import Foundation
import Network
import Security
import UIKit

struct HermesNativeTokenSet: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: TimeInterval
    let provider: String
    let userID: String

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case provider
        case userID = "user_id"
    }

}

enum HermesNativeOAuth {
    enum OAuthError: LocalizedError, Equatable {
        case invalidCallback
        case stateMismatch
        case authorizationRejected(String)

        var errorDescription: String? {
            switch self {
            case .invalidCallback:
                return "Hermes 登录回调无效。"
            case .stateMismatch:
                return "Hermes 登录校验失败，请重试。"
            case .authorizationRejected(let detail):
                return detail.isEmpty ? "Hermes 拒绝了登录请求。" : "Hermes 登录失败：\(detail)"
            }
        }
    }

    static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func authorizeURL(
        baseURL: URL,
        challenge: String,
        redirectURI: String,
        state: String,
        provider: String?
    ) -> URL? {
        var components = URLComponents(
            url: endpoint(baseURL: baseURL, path: "auth/native/authorize"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
        ]
        if let provider, !provider.isEmpty {
            components?.queryItems?.append(URLQueryItem(name: "provider", value: provider))
        }
        return components?.url
    }

    static func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw OAuthError.invalidCallback
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            values[item.name] = item.value ?? ""
        }
        if let error = values["error"] {
            throw OAuthError.authorizationRejected(values["error_description"] ?? error)
        }
        guard values["state"] == expectedState else { throw OAuthError.stateMismatch }
        guard let code = values["code"], !code.isEmpty else { throw OAuthError.invalidCallback }
        return code
    }

    static func randomBase64URL(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw KeychainStore.KeychainError.unexpectedStatus(status) }
        return base64URL(Data(bytes))
    }

    static func endpoint(baseURL: URL, path: String) -> URL {
        path.split(separator: "/").reduce(baseURL) { url, part in
            url.appendingPathComponent(String(part))
        }
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
final class HermesNativeAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = HermesNativeAuth()

    private let keychain = KeychainStore()
    private var webSession: ASWebAuthenticationSession?
    private var activeLoginProfileID: UUID?

    func validAccessToken(
        profileID: UUID,
        baseURL: URL,
        provider: String?,
        urlSession: URLSession
    ) async throws -> String {
        if let tokens = loadTokens(profileID: profileID) {
            if tokens.expiresAt > Date().timeIntervalSince1970 + 60 {
                return tokens.accessToken
            }
            if !tokens.refreshToken.isEmpty,
               let refreshed = try await refresh(tokens, baseURL: baseURL, urlSession: urlSession) {
                try saveTokens(refreshed, profileID: profileID)
                return refreshed.accessToken
            }
            try? deleteTokens(profileID: profileID)
        }

        let tokens = try await signIn(profileID: profileID, baseURL: baseURL, provider: provider, urlSession: urlSession)
        try saveTokens(tokens, profileID: profileID)
        return tokens.accessToken
    }

    func invalidate(profileID: UUID) {
        try? deleteTokens(profileID: profileID)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first
            ?? ASPresentationAnchor()
    }

    private func signIn(
        profileID: UUID,
        baseURL: URL,
        provider: String?,
        urlSession: URLSession
    ) async throws -> HermesNativeTokenSet {
        guard activeLoginProfileID == nil else {
            throw HermesClientError.authenticationRequired
        }
        activeLoginProfileID = profileID
        defer {
            activeLoginProfileID = nil
            webSession = nil
        }

        let verifier = try HermesNativeOAuth.randomBase64URL(byteCount: 32)
        let state = try HermesNativeOAuth.randomBase64URL(byteCount: 24)
        let listener = HermesOAuthLoopbackListener()
        let callback = try await listener.start()
        let redirectURI = callback.absoluteString
        guard let authorizationURL = HermesNativeOAuth.authorizeURL(
            baseURL: baseURL,
            challenge: HermesNativeOAuth.codeChallenge(for: verifier),
            redirectURI: redirectURI,
            state: state,
            provider: provider
        ) else {
            listener.cancel()
            throw HermesClientError.invalidResponse("无法生成 Hermes 登录地址")
        }

        let session = ASWebAuthenticationSession(url: authorizationURL, callbackURLScheme: nil) { _, error in
            if error != nil { listener.cancel(error: HermesClientError.authenticationRequired) }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        webSession = session
        guard session.start() else {
            listener.cancel()
            throw HermesClientError.authenticationRequired
        }

        let callbackURL: URL
        do {
            callbackURL = try await listener.waitForCallback()
        } catch {
            session.cancel()
            throw error
        }
        session.cancel()
        let code = try HermesNativeOAuth.authorizationCode(from: callbackURL, expectedState: state)
        return try await exchange(code: code, verifier: verifier, baseURL: baseURL, urlSession: urlSession)
    }

    private func exchange(
        code: String,
        verifier: String,
        baseURL: URL,
        urlSession: URLSession
    ) async throws -> HermesNativeTokenSet {
        var request = URLRequest(url: HermesNativeOAuth.endpoint(baseURL: baseURL, path: "auth/native/token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "code_verifier": verifier])
        return try await tokenResponse(for: request, urlSession: urlSession)
    }

    private func refresh(
        _ tokens: HermesNativeTokenSet,
        baseURL: URL,
        urlSession: URLSession
    ) async throws -> HermesNativeTokenSet? {
        var request = URLRequest(url: HermesNativeOAuth.endpoint(baseURL: baseURL, path: "auth/native/refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "refresh_token": tokens.refreshToken,
            "provider": tokens.provider,
        ])
        do {
            return try await tokenResponse(for: request, urlSession: urlSession)
        } catch HermesClientError.httpStatus(let status) where status == 401 {
            return nil
        }
    }

    private func tokenResponse(for request: URLRequest, urlSession: URLSession) async throws -> HermesNativeTokenSet {
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesClientError.invalidResponse("登录没有 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else { throw HermesClientError.httpStatus(http.statusCode) }
        do {
            return try JSONDecoder().decode(HermesNativeTokenSet.self, from: data)
        } catch {
            throw HermesClientError.invalidResponse("Hermes 登录令牌格式无效")
        }
    }

    private func loadTokens(profileID: UUID) -> HermesNativeTokenSet? {
        guard let data = keychain.data(for: KeychainStore.hermesTokenAccount(for: profileID)) else { return nil }
        return try? JSONDecoder().decode(HermesNativeTokenSet.self, from: data)
    }

    private func saveTokens(_ tokens: HermesNativeTokenSet, profileID: UUID) throws {
        try keychain.setData(
            try JSONEncoder().encode(tokens),
            for: KeychainStore.hermesTokenAccount(for: profileID)
        )
    }

    private func deleteTokens(profileID: UUID) throws {
        try keychain.deleteData(for: KeychainStore.hermesTokenAccount(for: profileID))
    }
}

private final class HermesOAuthLoopbackListener: @unchecked Sendable {
    enum ListenerError: LocalizedError {
        case failed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .failed(let detail): return "无法启动 Hermes 登录回调：\(detail)"
            case .timedOut: return "Hermes 登录超时，请重试。"
            }
        }
    }

    private let queue = DispatchQueue(label: "app.dsh.mobile.hermes-oauth")
    private var listener: NWListener?
    private var readyContinuation: CheckedContinuation<URL, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var callbackURL: URL?
    private var callbackError: Error?
    private var timeoutTask: Task<Void, Never>?

    func start() async throws -> URL {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = listener?.port else { return }
                self.resumeReady(with: .success(URL(string: "http://127.0.0.1:\(port.rawValue)/callback")!))
            case .failed(let error):
                self.resumeReady(with: .failure(ListenerError.failed(error.localizedDescription)))
                self.resumeCallback(with: .failure(ListenerError.failed(error.localizedDescription)))
            case .cancelled:
                self.resumeCallback(with: .failure(CancellationError()))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.receive(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.readyContinuation = continuation
                listener.start(queue: self.queue)
            }
        }
    }

    func waitForCallback() async throws -> URL {
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self?.queue.async { self?.resumeCallback(with: .failure(ListenerError.timedOut)) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let url = self.callbackURL {
                    continuation.resume(returning: url)
                } else if let error = self.callbackError {
                    continuation.resume(throwing: error)
                } else {
                    self.callbackContinuation = continuation
                }
            }
        }
    }

    func cancel() {
        cancel(error: CancellationError())
    }

    func cancel(error: Error) {
        queue.async {
            self.callbackError = error
            self.resumeCallback(with: .failure(error))
            self.timeoutTask?.cancel()
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let requestTarget = request.split(separator: "\r\n", maxSplits: 1).first?
                .split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let url = URL(string: requestTarget, relativeTo: URL(string: "http://127.0.0.1"))?.absoluteURL
            let html = "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'><body style='font:17px -apple-system;margin:64px 24px;text-align:center'><h2>✓ 已登录 Hermes</h2><p>现在可以返回 DSH App。</p>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            guard let url,
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  items.contains(where: { $0.name == "code" || $0.name == "error" }) else { return }
            self.callbackURL = url
            self.resumeCallback(with: .success(url))
        }
    }

    private func resumeReady(with result: Result<URL, Error>) {
        guard let continuation = readyContinuation else { return }
        readyContinuation = nil
        continuation.resume(with: result)
    }

    private func resumeCallback(with result: Result<URL, Error>) {
        guard let continuation = callbackContinuation else {
            if case .failure(let error) = result, callbackURL == nil { callbackError = error }
            return
        }
        callbackContinuation = nil
        timeoutTask?.cancel()
        listener?.cancel()
        listener = nil
        continuation.resume(with: result)
    }
}
