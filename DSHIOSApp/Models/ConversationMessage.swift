import Foundation

struct ConversationMessage: Identifiable, Equatable, Codable, Sendable {
    enum Role: String, Equatable, Codable, Sendable {
        case user
        case assistant
        case activity
    }

    let id: String
    let role: Role
    var text: String
    var reasoning: String
    var timestamp: Date
    var sequence: Int
    var isStreaming: Bool
    var isPending: Bool
    /// Attachments (images / files) carried by this message.
    /// Used for local rendering; backend multimodal protocol TBD.
    var attachments: [MessageAttachment]

    init(
        id: String,
        role: Role,
        text: String,
        reasoning: String,
        timestamp: Date,
        sequence: Int,
        isStreaming: Bool,
        isPending: Bool,
        attachments: [MessageAttachment] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.timestamp = timestamp
        self.sequence = sequence
        self.isStreaming = isStreaming
        self.isPending = isPending
        self.attachments = attachments
    }
}

struct ConversationProjector: Sendable {
    private var eventsBySequence: [Int: DSHSessionEvent] = [:]

    mutating func replace(with events: [DSHSessionEvent]) {
        eventsBySequence.removeAll(keepingCapacity: true)
        for event in events {
            eventsBySequence[event.sequence] = event
        }
    }

    mutating func apply(_ event: DSHSessionEvent) {
        eventsBySequence[event.sequence] = event
    }

    func messages() -> [ConversationMessage] {
        var output: [ConversationMessage] = []
        var assistantIndexes: [String: Int] = [:]
        var toolIndexes: [String: Int] = [:]

        for event in eventsBySequence.values.sorted(by: { $0.sequence < $1.sequence }) {
            switch event.type {
            case "user/message":
                guard event.data["source"]?["kind"]?.stringValue == "user" else { continue }
                let content = Self.content(from: event.data["content"])
                guard !content.text.isEmpty || !content.attachments.isEmpty else { continue }
                output.append(ConversationMessage(
                    id: event.data["id"]?.stringValue ?? "user-\(event.sequence)",
                    role: .user,
                    text: content.text,
                    reasoning: "",
                    timestamp: event.time,
                    sequence: event.sequence,
                    isStreaming: false,
                    isPending: false,
                    attachments: content.attachments
                ))

            case "assistant/chunk":
                let key = Self.stepKey(event.data)
                guard let chunk = event.data["chunk"] else { continue }
                let index: Int
                if let existing = assistantIndexes[key] {
                    index = existing
                } else {
                    index = output.count
                    assistantIndexes[key] = index
                    output.append(ConversationMessage(
                        id: "assistant-\(key)",
                        role: .assistant,
                        text: "",
                        reasoning: "",
                        timestamp: event.time,
                        sequence: event.sequence,
                        isStreaming: true,
                        isPending: false
                    ))
                }
                Self.apply(chunk: chunk, to: &output[index])

            case "assistant/message":
                let key = Self.stepKey(event.data)
                let message = event.data["message"] ?? event.data
                let content = Self.content(from: message["content"])
                guard !content.text.isEmpty || !content.reasoning.isEmpty || !content.attachments.isEmpty else { continue }

                let projected = ConversationMessage(
                    id: message["id"]?.stringValue ?? "assistant-\(key)",
                    role: .assistant,
                    text: content.text,
                    reasoning: content.reasoning,
                    timestamp: event.time,
                    sequence: event.sequence,
                    isStreaming: false,
                    isPending: false,
                    attachments: content.attachments
                )
                if let index = assistantIndexes[key] {
                    output[index] = projected
                } else {
                    assistantIndexes[key] = output.count
                    output.append(projected)
                }

            case "tool/call":
                let callId = event.data["callId"]?.stringValue ?? "\(event.sequence)"
                let name = event.data["name"]?.stringValue ?? "工具"
                toolIndexes[callId] = output.count
                output.append(ConversationMessage(
                    id: "tool-\(callId)",
                    role: .activity,
                    text: "正在使用 \(name)",
                    reasoning: "",
                    timestamp: event.time,
                    sequence: event.sequence,
                    isStreaming: true,
                    isPending: false
                ))

            case "tool/result":
                let message = event.data["message"] ?? event.data
                let callId = message["source"]?["callId"]?.stringValue ?? event.data["callId"]?.stringValue
                if let callId, let index = toolIndexes[callId] {
                    output[index].text = output[index].text.replacingOccurrences(of: "正在使用", with: "已使用")
                    output[index].isStreaming = false
                }

            case "turn/end":
                guard let reason = event.data["reason"]?["kind"]?.stringValue else { continue }
                let labels = [
                    "aborted": "生成已停止",
                    "blocked": "本轮请求被阻止",
                    "max-tokens": "已达到本轮长度上限",
                    "error": "本轮生成失败",
                    "interrupted": "本轮生成已中断"
                ]
                if let label = labels[reason] {
                    output.append(ConversationMessage(
                        id: "turn-end-\(event.sequence)",
                        role: .activity,
                        text: label,
                        reasoning: "",
                        timestamp: event.time,
                        sequence: event.sequence,
                        isStreaming: false,
                        isPending: false
                    ))
                }

            default:
                continue
            }
        }

        return output.filter { !$0.text.isEmpty || !$0.reasoning.isEmpty || !$0.attachments.isEmpty || $0.role == .activity }
    }

    static func userRPCId(from event: DSHSessionEvent) -> String? {
        guard event.type == "user/message" else { return nil }
        return event.data["source"]?["rpcId"]?.stringValue
    }

    static func stepKey(_ data: JSONValue) -> String {
        let message = data["message"]
        let source = message?["source"] ?? data["source"]
        let turnValue = data["turn"] ?? message?["turn"] ?? source?["turn"]
        let stepValue = data["step"] ?? message?["step"] ?? source?["step"]
        let turn = turnValue?.stringValue ?? String(turnValue?.intValue ?? 0)
        let step = stepValue?.stringValue ?? String(stepValue?.intValue ?? 0)
        return "\(turn)-\(step)"
    }

    static func optionalStepKey(_ data: JSONValue) -> String? {
        let message = data["message"]
        let source = message?["source"] ?? data["source"]
        guard data["turn"] != nil || data["step"] != nil
                || message?["turn"] != nil || message?["step"] != nil
                || source?["turn"] != nil || source?["step"] != nil else {
            return nil
        }
        return stepKey(data)
    }

    private static func apply(chunk: JSONValue, to message: inout ConversationMessage) {
        switch chunk["type"]?.stringValue {
        case "text-delta":
            message.text += chunk["text"]?.stringValue ?? ""
        case "reasoning-delta":
            message.reasoning += chunk["text"]?.stringValue ?? ""
        case "block-end":
            let block = chunk["block"]
            if block?["type"]?.stringValue == "text", message.text.isEmpty {
                message.text = block?["text"]?.stringValue ?? ""
            } else if block?["type"]?.stringValue == "reasoning", message.reasoning.isEmpty {
                message.reasoning = block?["text"]?.stringValue ?? ""
            }
        case "finish":
            message.isStreaming = false
        default:
            break
        }
    }

    private static func content(from value: JSONValue?) -> (text: String, reasoning: String, attachments: [MessageAttachment]) {
        guard let blocks = value?.arrayValue else { return ("", "", []) }
        var text: [String] = []
        var reasoning: [String] = []
        var attachments: [MessageAttachment] = []
        for block in blocks {
            switch block["type"]?.stringValue {
            case "text":
                if let value = block["text"]?.stringValue, !value.isEmpty { text.append(value) }
            case "reasoning":
                if let value = block["text"]?.stringValue, !value.isEmpty { reasoning.append(value) }
            case "image":
                if let att = Self.imageAttachment(from: block) {
                    attachments.append(att)
                }
            case "file":
                if let att = Self.fileAttachment(from: block) {
                    attachments.append(att)
                }
            default:
                continue
            }
        }
        return (
            text.joined(separator: "\n\n"),
            reasoning.joined(separator: "\n\n"),
            attachments
        )
    }

    private static func imageAttachment(from block: JSONValue) -> MessageAttachment? {
        // Backend may nest metadata under "attachment"; prefer those fields.
        let att = block["attachment"]?.objectValue
        func field(_ key: String) -> JSONValue? {
            if let att, let v = att[key] { return v }
            return block[key]
        }

        let attachmentId = field("attachmentId")?.stringValue
        // Use attachmentId as the stable local id when available (it is the
        // canonical content-addressable reference), otherwise fall back.
        let rawId = block["id"]?.stringValue
        let id = attachmentId ?? rawId ?? UUID().uuidString
        let name = field("name")?.stringValue ?? "image.png"
        let mediaType = field("mediaType")?.stringValue ?? "image/png"
        let base64Data = field("data")?.stringValue
        let size: Int64 = {
            if let bytes = field("bytes")?.intValue { return Int64(bytes) }
            if let bytes = field("size")?.intValue { return Int64(bytes) }
            if let base64 = base64Data { return Int64(base64.count * 3 / 4) }
            return 0
        }()
        return MessageAttachment(
            id: id,
            kind: .image,
            name: name,
            size: size,
            mimeType: mediaType,
            attachmentId: attachmentId,
            base64Data: base64Data
        )
    }

    private static func fileAttachment(from block: JSONValue) -> MessageAttachment? {
        let att = block["attachment"]?.objectValue
        func field(_ key: String) -> JSONValue? {
            if let att, let v = att[key] { return v }
            return block[key]
        }
        let attachmentId = field("attachmentId")?.stringValue
        let rawId = block["id"]?.stringValue
        let id = attachmentId ?? rawId ?? UUID().uuidString
        let name = field("name")?.stringValue ?? "file"
        let mediaType = field("mediaType")?.stringValue
        let size = Int64(field("bytes")?.intValue ?? field("size")?.intValue ?? 0)
        return MessageAttachment(
            id: id,
            kind: .file,
            name: name,
            size: size,
            mimeType: mediaType,
            attachmentId: attachmentId
        )
    }
}

// MARK: - Session Content Cache

/// Cached snapshot of a session's displayable content, persisted to disk so that
/// switching back to a previously opened session shows messages instantly while
/// the server refresh runs in the background.
struct CachedSessionContent: Codable, Sendable {
    let messages: [ConversationMessage]
    let title: String
    let contextUsageRatio: Double?
    let cacheHitRatio: Double?
    let permissionOptions: [AgentPermissionOption]
    let currentPermission: String?
    let savedAt: Date
}

enum SessionContentCache {
    private static let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("session_content", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func fileURL(sessionID: String) -> URL {
        let safe = sessionID.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safe).json")
    }

    static func load(sessionID: String) -> CachedSessionContent? {
        let url = fileURL(sessionID: sessionID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachedSessionContent.self, from: data)
    }

    static func save(sessionID: String, content: CachedSessionContent) {
        let url = fileURL(sessionID: sessionID)
        guard let data = try? JSONEncoder().encode(content) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
