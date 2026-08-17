import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(value)
    }

    var doubleValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}

struct DSHRPCError: Codable, Error, Sendable {
    let code: String
    let message: String
    let details: JSONValue?
}

enum DSHClientError: LocalizedError {
    case invalidURL
    case invalidResponse(String)
    case httpStatus(Int, String)
    case server(DSHRPCError)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "服务器地址无效"
        case .invalidResponse(let reason):
            return "DSH 返回了无法识别的数据：\(reason)"
        case .httpStatus(let status, let body):
            switch status {
            case 401:
                return "认证失败。请返回服务器列表，左滑该服务器并选择“编辑”，重新填写用户名和密码。"
            case 403:
                return "服务器拒绝访问（HTTP 403），请检查代理权限和 DSH 的可信 Host 配置。"
            default:
                let isHTML = body.localizedCaseInsensitiveContains("<html")
                return body.isEmpty || isHTML
                    ? "服务器连接失败（HTTP \(status)）"
                    : "服务器连接失败（HTTP \(status)）：\(body)"
            }
        case .server(let error):
            return error.message
        }
    }
}

struct DSHRPCResponse: Decodable {
    struct Result: Decodable {
        let ok: Bool
        let value: JSONValue?
        let error: DSHRPCError?
    }

    let type: String
    let rpcId: String
    let result: Result
}

struct DSHServerRequest: Decodable, Sendable {
    let type: String
    let rpcId: String
    let method: String
    let payload: JSONValue
}

struct DSHRPCReceipt: Decodable, Sendable {
    let accepted: Bool
    let reason: String?
}

struct DSHSessionEvent: Equatable, Sendable {
    let type: String
    let sequence: Int
    let time: Date
    let data: JSONValue
    let surfaceOperation: JSONValue?

    init(json: JSONValue) throws {
        guard
            let type = json["type"]?.stringValue,
            let sequence = json["seq"]?.intValue,
            let milliseconds = json["time"]?.doubleValue,
            let data = json["data"]
        else {
            throw DSHClientError.invalidResponse("会话事件缺少必要字段")
        }
        self.type = type
        self.sequence = sequence
        self.time = Date(timeIntervalSince1970: milliseconds / 1_000)
        self.data = data
        self.surfaceOperation = json["surfaceOp"]
    }
}

struct DSHSessionSummary: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var updatedAt: Date
    var isRunning: Bool
    var isBlank: Bool
    var workingDirectory: String?

    init(json: JSONValue) throws {
        guard
            let id = json["sessionId"]?.stringValue,
            let milliseconds = json["updatedAt"]?.doubleValue
        else {
            throw DSHClientError.invalidResponse("会话摘要缺少必要字段")
        }

        let projectedTitle = json["projections"]?["values"]?["title"]?.stringValue
        self.id = id
        self.title = projectedTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "新对话"
        self.updatedAt = Date(timeIntervalSince1970: milliseconds / 1_000)
        self.isRunning = json["running"]?.boolValue ?? false
        self.isBlank = json["blank"]?.boolValue ?? false
        self.workingDirectory = json["cwd"]?.stringValue
    }

    init(id: String, title: String = "新对话") {
        self.id = id
        self.title = title
        self.updatedAt = Date()
        self.isRunning = false
        self.isBlank = true
        self.workingDirectory = nil
    }
}

struct DSHHistoryPage: Sendable {
    let events: [DSHSessionEvent]
    let hasMore: Bool
    let title: String?

    init(json: JSONValue) throws {
        guard let rawEvents = json["events"]?.arrayValue else {
            throw DSHClientError.invalidResponse("历史记录缺少 events")
        }
        events = try rawEvents.compactMap { item in
            guard let event = item["event"] else { return nil }
            return try DSHSessionEvent(json: event)
        }
        hasMore = json["hasMore"]?.boolValue ?? false
        title = json["projections"]?["values"]?["title"]?.stringValue
    }
}

struct DSHWorkspace: Identifiable, Hashable, Sendable {
    let id: String
    let path: String
    let title: String
    let sessionIDs: [String]

    init(json: JSONValue) throws {
        guard
            let id = json["workspaceId"]?.stringValue,
            let path = json["path"]?.stringValue,
            let title = json["title"]?.stringValue,
            let rawSessionIDs = json["sessionIds"]?.arrayValue
        else {
            throw DSHClientError.invalidResponse("工作区缺少必要字段")
        }
        self.id = id
        self.path = path
        self.title = title
        self.sessionIDs = rawSessionIDs.compactMap(\.stringValue)
    }
}

struct DSHWorkspaceList: Sendable {
    let items: [DSHWorkspace]
    let archivedSessionIDs: Set<String>

    init(json: JSONValue) throws {
        guard let rawItems = json["items"]?.arrayValue else {
            throw DSHClientError.invalidResponse("工作区列表缺少 items")
        }
        items = try rawItems.map(DSHWorkspace.init(json:))
        archivedSessionIDs = Set(json["archivedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }
}


