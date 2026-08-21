import Foundation

struct ServerProfile: Codable, Hashable, Identifiable {
    let id: UUID
    var kind: AgentServerKind
    var name: String
    var baseURL: URL
    var username: String

    init(
        id: UUID = UUID(),
        kind: AgentServerKind = .dsh,
        name: String,
        baseURL: URL,
        username: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.baseURL = baseURL
        self.username = username
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, baseURL, username
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decodeIfPresent(AgentServerKind.self, forKey: .kind) ?? .dsh
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(URL.self, forKey: .baseURL)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
    }
}

extension ServerProfile {
    var displayAddress: String {
        guard let host = baseURL.host else { return baseURL.absoluteString }
        var address = host.contains(":") ? "[\(host)]" : host
        if let port = baseURL.port { address += ":\(port)" }
        if !baseURL.path.isEmpty && baseURL.path != "/" { address += baseURL.path }
        return address
    }

    enum ValidationError: LocalizedError, Equatable {
        case missingName
        case invalidURL
        case unsupportedScheme
        case pathNotSupported
        case insecureRemoteURL

        var errorDescription: String? {
            switch self {
            case .missingName:
                return "请输入服务器名称。"
            case .invalidURL:
                return "请输入有效的服务器地址。"
            case .unsupportedScheme:
                return "服务器地址必须使用 HTTPS，局域网主机可使用 HTTP。"
            case .pathNotSupported:
                return "DSH 必须部署在域名根路径；服务器地址不能包含查询参数或片段。"
            case .insecureRemoteURL:
                return "公网服务器必须使用 HTTPS。HTTP 仅允许 localhost、.local 或不含点号的局域网主机名。"
            }
        }
    }

    static func validated(
        id: UUID = UUID(),
        kind: AgentServerKind = .dsh,
        name rawName: String,
        address rawAddress: String,
        username rawUsername: String
    ) throws -> ServerProfile {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ValidationError.missingName }

        var address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw ValidationError.invalidURL }
        if !address.contains("://") {
            address = "https://\(address)"
        }

        guard var components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              scheme == "https" || scheme == "http" else {
            throw ValidationError.unsupportedScheme
        }

        let path = components.percentEncodedPath
        guard (kind == .hermes || kind == .codex || path.isEmpty || path == "/"),
              components.query == nil,
              components.fragment == nil,
              components.user == nil,
              components.password == nil else {
            throw ValidationError.pathNotSupported
        }

        if scheme == "http" && !isLocalHostname(host) {
            throw ValidationError.insecureRemoteURL
        }

        components.scheme = scheme
        components.host = host
        components.path = (kind == .dsh || kind == .codex)
            ? ""
            : path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).nilIfEmpty.map { "/\($0)" } ?? ""
        guard let url = components.url else { throw ValidationError.invalidURL }

        return ServerProfile(
            id: id,
            kind: kind,
            name: name,
            baseURL: url,
            username: rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func isLocalHostname(_ host: String) -> Bool {
        host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
            || host.hasSuffix(".local")
            || !host.contains(".")
    }
}

