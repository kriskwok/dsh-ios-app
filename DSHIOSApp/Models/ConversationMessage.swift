import Foundation

struct ConversationMessage: Identifiable, Equatable, Sendable {
    enum Role: Equatable, Sendable {
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
                guard !content.text.isEmpty else { continue }
                output.append(ConversationMessage(
                    id: event.data["id"]?.stringValue ?? "user-\(event.sequence)",
                    role: .user,
                    text: content.text,
                    reasoning: "",
                    timestamp: event.time,
                    sequence: event.sequence,
                    isStreaming: false,
                    isPending: false
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
                guard !content.text.isEmpty || !content.reasoning.isEmpty else { continue }

                let projected = ConversationMessage(
                    id: message["id"]?.stringValue ?? "assistant-\(key)",
                    role: .assistant,
                    text: content.text,
                    reasoning: content.reasoning,
                    timestamp: event.time,
                    sequence: event.sequence,
                    isStreaming: false,
                    isPending: false
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

        return output.filter { !$0.text.isEmpty || !$0.reasoning.isEmpty || $0.role == .activity }
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

    private static func content(from value: JSONValue?) -> (text: String, reasoning: String) {
        guard let blocks = value?.arrayValue else { return ("", "") }
        var text: [String] = []
        var reasoning: [String] = []
        for block in blocks {
            switch block["type"]?.stringValue {
            case "text":
                if let value = block["text"]?.stringValue, !value.isEmpty { text.append(value) }
            case "reasoning":
                if let value = block["text"]?.stringValue, !value.isEmpty { reasoning.append(value) }
            default:
                continue
            }
        }
        return (text.joined(separator: "\n\n"), reasoning.joined(separator: "\n\n"))
    }
}
