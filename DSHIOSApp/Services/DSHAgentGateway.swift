import Foundation

final class DSHAgentGateway: AgentGateway, @unchecked Sendable {
    private let client: DSHAPIClient

    init(profile: ServerProfile, password: String) {
        client = DSHAPIClient(profile: profile, password: password)
    }

    func connect() async throws {
        try await client.authenticate()
    }

    func navigation() async throws -> AgentNavigationSnapshot {
        try await connect()
        let sessionResult = try await client.call(method: "session.list")
        let rawSessions = sessionResult.value["items"]?.arrayValue ?? []
        let dshSessions = try rawSessions.map(DSHSessionSummary.init(json:))
        let sessions = dshSessions.map(Self.agentSession).sorted { $0.updatedAt > $1.updatedAt }

        let workspaceResult = try await client.call(method: "workspace.list")
        let list = try DSHWorkspaceList(json: workspaceResult.value)
        return AgentNavigationSnapshot(
            sessions: sessions,
            workspaces: list.items.map {
                AgentWorkspace(id: $0.id, path: $0.path, title: $0.title, sessionIDs: $0.sessionIDs)
            },
            archivedSessionIDs: list.archivedSessionIDs
        )
    }

    func openSession(_ session: AgentSessionSummary) async throws -> AgentConversationContext {
        let result = try await client.call(
            method: "session.history",
            payload: ["sessionId": .string(session.id), "maxMessages": .number(80)]
        )
        let history = try DSHHistoryPage(json: result.value)
        var projector = ConversationProjector()
        projector.replace(with: history.events)
        let permissions = result.value["projections"]?["values"]?["permissions"]
        let permissionOptions = permissions?["options"]?.arrayValue?.compactMap { opt -> AgentPermissionOption? in
            guard let value = opt["value"]?.stringValue else { return nil }
            return AgentPermissionOption(value: value, name: opt["name"]?.stringValue ?? value)
        }
        let currentPermission = permissions?["currentValue"]?.stringValue
        return AgentConversationContext(
            runtimeSessionID: session.id,
            session: session,
            messages: projector.messages(),
            title: history.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? session.title,
            isRunning: Self.runningState(from: history.events, fallback: session.isRunning),
            currentModel: nil,
            metrics: Self.metrics(from: result.value),
            permissionOptions: permissionOptions,
            currentPermission: currentPermission
        )
    }

    /// Extract session metrics from a history response.
    /// DSH exposes tokenUsage / contextPressure as session projections under
    /// `projections.values`, alongside `title`.
    private static func metrics(from history: JSONValue) -> AgentSessionMetrics? {
        if let projections = history["projections"]?["values"],
           let m = AgentSessionMetrics(json: projections) {
            return m
        }
        // Fallback: top-level fields (other server shapes).
        return AgentSessionMetrics(json: history)
    }

    func createSession(in workspace: AgentWorkspace?) async throws -> AgentConversationContext {
        var payload: [String: JSONValue] = [:]
        if let workspace { payload["workspaceId"] = .string(workspace.id) }
        let result = try await client.call(method: "session.create", payload: payload)
        guard let id = result.value["sessionId"]?.stringValue else {
            throw DSHClientError.invalidResponse("创建结果缺少 sessionId")
        }
        let session = AgentSessionSummary(
            id: id,
            isBlank: true,
            workingDirectory: workspace?.path
        )
        return AgentConversationContext(
            runtimeSessionID: id,
            session: session,
            messages: [],
            title: "新对话",
            isRunning: false,
            currentModel: nil
        )
    }

    func send(text: String, sessionID: String, requestID: String) async throws {
        try await send(images: [], text: text, sessionID: sessionID, requestID: requestID)
    }

    func send(images: [ImageContentBlock], text: String, sessionID: String, requestID: String) async throws {
        var content: [JSONValue] = []
        for img in images {
            content.append(.object([
                "type": .string("image"),
                "mediaType": .string(img.mediaType),
                "data": .string(img.data.base64EncodedString()),
                "name": .string(img.name)
            ]))
        }
        if !text.isEmpty {
            content.append(.object(["type": .string("text"), "text": .string(text)]))
        }
        _ = try await client.call(
            method: "session.prompt",
            payload: [
                "sessionId": .string(sessionID),
                "mode": .string("queue"),
                "content": .array(content),
                "clientTimeZone": .string(TimeZone.current.identifier)
            ],
            rpcId: requestID
        )
    }

    func fetchAttachment(sessionID: String, attachmentId: String) async throws -> Data {
        print("[Attachment] fetch session=\(sessionID) id=\(attachmentId)")
        let data = try await client.callRawData(
            method: "session.attachment",
            payload: [
                "sessionId": .string(sessionID),
                "attachmentId": .string(attachmentId)
            ]
        )
        print("[Attachment] response bytes=\(data.count) prefix=\(data.prefix(20).map { String(format: "%02x", $0) }.joined())")

        // The response may be:
        // 1. Raw binary data (image bytes directly)
        // 2. A JSON RPC envelope with base64 in result.value
        // 3. A JSON object with a "data" field containing base64
        // Try JSON parsing first; if it fails, treat as raw binary.
        if let envelope = try? JSONDecoder().decode(DSHRPCResponse.self, from: data),
           envelope.result.ok {
            if let base64 = envelope.result.value?.stringValue,
               let decoded = Data(base64Encoded: base64) {
                print("[Attachment] decoded from value.stringValue, \(decoded.count) bytes")
                return decoded
            }
            if let base64 = envelope.result.value?["data"]?.stringValue,
               let decoded = Data(base64Encoded: base64) {
                print("[Attachment] decoded from value[data], \(decoded.count) bytes")
                return decoded
            }
            print("[Attachment] envelope ok but no recognizable data field, valueKeys=\(envelope.result.value?.objectValue?.keys.map { $0 } ?? [])")
        }

        // Try parsing as a plain JSON object with data field (non-envelope).
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let base64 = json["data"] as? String,
           let decoded = Data(base64Encoded: base64) {
            print("[Attachment] decoded from plain json[data], \(decoded.count) bytes")
            return decoded
        }

        // Fallback: treat the entire response body as raw binary data.
        // UIImage can be created from valid image data regardless of format.
        if !data.isEmpty {
            print("[Attachment] using raw binary fallback, \(data.count) bytes")
            return data
        }

        throw DSHClientError.invalidResponse("session.attachment 返回了空数据或无法识别的格式")
    }

    func cancel(sessionID: String) async throws {
        _ = try await client.call(method: "session.cancel", payload: ["sessionId": .string(sessionID)])
    }

    func setPermission(sessionID: String, preset: String) async throws {
        let agentId = sessionID.hasPrefix("session-") ? sessionID : "session-\(sessionID)"
        _ = try await client.call(
            method: "commands/execute",
            payload: [
                "args": .object([
                    "agentId": .string(agentId),
                    "line": .string("/permission \(preset)"),
                    "images": .array([])
                ])
            ]
        )
    }

    func renameSession(_ sessionID: String, title: String) async throws {
        print("[DSH-Manage] rename session=\(sessionID) title=\(title)")
        do {
            _ = try await client.call(
                method: "session.rename",
                payload: [
                    "sessionId": .string(sessionID),
                    "title": .string(title)
                ]
            )
            print("[DSH-Manage] rename success")
        } catch {
            print("[DSH-Manage] rename failed: \(error)")
            throw error
        }
    }

    func archiveSession(_ sessionID: String, archived: Bool) async throws {
        print("[DSH-Manage] archive session=\(sessionID) archived=\(archived)")
        do {
            let result = try await client.call(
                method: "workspace.archiveSession",
                payload: [
                    "sessionId": .string(sessionID),
                    "archived": .bool(archived)
                ]
            )
            print("[DSH-Manage] archive success: \(result.value)")
        } catch {
            print("[DSH-Manage] archive failed: \(error)")
            throw error
        }
    }

    func respond(to approval: AgentApprovalRequest, choice: AgentApprovalChoice) async throws {
        guard let rpcID = approval.responseToken else {
            throw DSHClientError.invalidResponse("审批缺少响应标识")
        }
        let outcome: String
        switch choice {
        case .once: outcome = "allowed-once"
        case .deny: outcome = "rejected"
        case .session, .always:
            throw DSHClientError.invalidResponse("DSH 仅支持允许一次或拒绝")
        }
        try await client.respond(rpcId: rpcID, value: [
            "sessionId": .string(approval.sessionID),
            "approvalId": .string(approval.id),
            "outcome": .string(outcome)
        ])
    }

    func respond(to question: AgentQuestionRequest, answers: [AgentQuestionAnswer]) async throws {
        guard let rpcID = question.responseToken else {
            throw DSHClientError.invalidResponse("提问缺少响应标识")
        }
        let answerItems: [JSONValue] = answers.map { answer in
            var item: [String: JSONValue] = ["id": .string(answer.id)]
            if !answer.selected.isEmpty {
                item["selected"] = .array(answer.selected.map { .string($0) })
            }
            if let custom = answer.custom, !custom.isEmpty {
                item["custom"] = .string(custom)
            }
            return .object(item)
        }
        try await client.respond(rpcId: rpcID, value: [
            "sessionId": .string(question.sessionID),
            "answer": .object(["answers": .array(answerItems)])
        ])
    }

    func respondCancelled(to question: AgentQuestionRequest) async throws {
        guard let rpcID = question.responseToken else {
            throw DSHClientError.invalidResponse("提问缺少响应标识")
        }
        try await client.respondError(
            rpcId: rpcID,
            code: "cancelled",
            message: "the user closed this question request"
        )
    }

    func events() -> AsyncThrowingStream<AgentGatewayEvent, Error> {
        AsyncThrowingStream { continuation in
            let muxTask = Task {
                do {
                    for try await request in client.eventStream(path: "events.mux") {
                        continuation.yield(.connected)
                        if let event = try Self.mapMux(request) {
                            continuation.yield(event)
                        }
                    }
                } catch {
                    if !Task.isCancelled { continuation.finish(throwing: error) }
                }
            }
            let hostTask = Task {
                do {
                    for try await request in client.eventStream(path: "events.host") {
                        continuation.yield(.connected)
                        if request.method == "host/session-status",
                           let sessionID = request.payload["sessionId"]?.stringValue,
                           let running = request.payload["running"]?.boolValue {
                            continuation.yield(.running(sessionID: sessionID, value: running))
                        }
                    }
                } catch {
                    if !Task.isCancelled { continuation.finish(throwing: error) }
                }
            }
            continuation.onTermination = { @Sendable _ in
                muxTask.cancel()
                hostTask.cancel()
            }
        }
    }

    func close() {}

    func fetchModels(sessionID: String) async throws -> AgentModelCatalog {
        let result = try await client.call(
            method: "session.models",
            payload: ["sessionId": .string(sessionID)]
        )
        let value = result.value
        let current: AgentModelSelection? = {
            guard let current = value["current"],
                  let provider = current["provider"]?.stringValue,
                  let model = current["model"]?.stringValue else { return nil }
            let reasoning = ReasoningLevel(rawValue: current["reasoningEffort"]?.stringValue ?? "")
            return AgentModelSelection(providerID: provider, modelID: model, reasoningLevel: reasoning)
        }()
        let reasoningLevel = ReasoningLevel(rawValue: value["current"]?["reasoningEffort"]?.stringValue ?? "")
            ?? current?.reasoningLevel
        let reasoningLevels: [ReasoningLevel]? = {
            guard let rawLevels = value["reasoningLevels"]?.arrayValue else { return nil }
            let levels = rawLevels.compactMap { ReasoningLevel(rawValue: $0.stringValue ?? "") }
            return levels.isEmpty ? nil : levels
        }()
        var mergedGroups: [String: AgentModelGroup] = [:]
        var groupOrder: [String] = []
        for rawGroup in value["groups"]?.arrayValue ?? [] {
            guard let groupID = rawGroup["id"]?.stringValue else { continue }
            let groupName = rawGroup["name"]?.stringValue ?? groupID
            let isOfficial = rawGroup["official"]?.boolValue ?? false
            let models = (rawGroup["models"]?.arrayValue ?? []).compactMap { rawModel -> AgentModel? in
                guard let modelID = rawModel["id"]?.stringValue else { return nil }
                let modelLevels = Self.parseReasoningLevels(rawModel["reasoning"]?["efforts"])
                let defaultLevel = rawModel["reasoning"]?["defaultEffort"]?.stringValue
                    .flatMap(ReasoningLevel.init)
                return AgentModel(
                    id: modelID,
                    name: rawModel["name"]?.stringValue ?? modelID,
                    providerID: groupID,
                    providerName: groupName,
                    isOfficial: isOfficial,
                    description: rawModel["description"]?.stringValue?.nilIfEmpty,
                    reasoningLevels: modelLevels,
                    defaultReasoningLevel: defaultLevel
                )
            }
            if let existing = mergedGroups[groupID] {
                mergedGroups[groupID] = AgentModelGroup(
                    id: groupID,
                    name: existing.name,
                    isOfficial: existing.isOfficial || isOfficial,
                    models: existing.models + models
                )
            } else {
                groupOrder.append(groupID)
                mergedGroups[groupID] = AgentModelGroup(id: groupID, name: groupName, isOfficial: isOfficial, models: models)
            }
        }
        let groups = groupOrder.compactMap { mergedGroups[$0] }
        return AgentModelCatalog(groups: groups, currentModel: current, currentReasoningLevel: reasoningLevel, reasoningLevels: reasoningLevels)
    }

    static func parseReasoningLevels(_ value: JSONValue?) -> [ReasoningLevel] {
        guard let array = value?.arrayValue, !array.isEmpty else { return [] }
        return array.compactMap { item in
            if let str = item.stringValue { return ReasoningLevel(rawValue: str) }
            if let effort = item["reasoningEffort"]?.stringValue { return ReasoningLevel(rawValue: effort) }
            if let effort = item["effort"]?.stringValue { return ReasoningLevel(rawValue: effort) }
            if let id = item["id"]?.stringValue { return ReasoningLevel(rawValue: id) }
            return nil
        }
    }

    func selectModel(_ selection: AgentModelSelection, sessionID: String) async throws -> AgentModelSelection? {
        var payload: [String: JSONValue] = [
            "sessionId": .string(sessionID),
            "provider": .string(selection.providerID),
            "model": .string(selection.modelID)
        ]
        if let level = selection.reasoningLevel {
            payload["reasoningEffort"] = .string(level.rawValue)
        }
        let result = try await client.call(
            method: "session.selectModel",
            payload: payload
        )
        guard let selected = result.value["selected"],
              let provider = selected["provider"]?.stringValue,
              let model = selected["model"]?.stringValue else { return nil }
        let reasoning = ReasoningLevel(rawValue: selected["reasoningEffort"]?.stringValue ?? "")
        return AgentModelSelection(providerID: provider, modelID: model, reasoningLevel: reasoning)
    }

    static func mapMux(_ request: DSHServerRequest) throws -> AgentGatewayEvent? {
        switch request.method {
        case "approval/requested":
            guard let sessionID = request.payload["sessionId"]?.stringValue,
                  let approvalID = request.payload["approvalId"]?.stringValue,
                  let toolName = request.payload["toolName"]?.stringValue else { return nil }
            return .approvalRequested(AgentApprovalRequest(
                id: approvalID,
                sessionID: sessionID,
                responseToken: request.rpcId,
                toolName: toolName,
                description: request.payload["reason"]?.stringValue
                    ?? "工具 \(toolName) 请求越权执行",
                command: request.payload["command"]?.stringValue,
                callID: request.payload["callId"]?.stringValue,
                choices: [.deny, .once],
                isSmartDenied: false,
                waitsForResolutionEvent: true
            ))
        case "approval/resolved":
            guard let sessionID = request.payload["sessionId"]?.stringValue,
                  let approvalID = request.payload["approvalId"]?.stringValue else { return nil }
            return .approvalResolved(
                sessionID: sessionID,
                approvalID: approvalID,
                outcome: request.payload["outcome"]?.stringValue ?? ""
            )
        case "question/requested":
            guard let sessionID = request.payload["sessionId"]?.stringValue,
                  let rawQuestions = request.payload["questions"]?.arrayValue else { return nil }
            let questions = rawQuestions.compactMap { raw -> AgentQuestion? in
                guard let id = raw["id"]?.stringValue,
                      let question = raw["question"]?.stringValue else { return nil }
                let options = (raw["options"]?.arrayValue ?? []).compactMap { option -> AgentQuestionOption? in
                    guard let label = option["label"]?.stringValue else { return nil }
                    return AgentQuestionOption(
                        id: label,
                        label: label,
                        description: option["description"]?.stringValue
                    )
                }
                return AgentQuestion(
                    id: id,
                    question: question,
                    detail: raw["detail"]?.stringValue,
                    header: raw["header"]?.stringValue,
                    options: options,
                    multiSelect: raw["multiSelect"]?.boolValue ?? false
                )
            }
            guard !questions.isEmpty else { return nil }
            return .questionRequested(AgentQuestionRequest(
                id: request.rpcId,
                sessionID: sessionID,
                responseToken: request.rpcId,
                questions: questions,
                waitsForResolutionEvent: true
            ))
        case "question/resolved":
            guard let sessionID = request.payload["sessionId"]?.stringValue,
                  let questionRpcId = request.payload["questionRpcId"]?.stringValue else { return nil }
            return .questionResolved(
                sessionID: sessionID,
                questionRpcId: questionRpcId,
                outcome: request.payload["outcome"]?.stringValue ?? ""
            )
        case "session/event":
            guard let sessionID = request.payload["sessionId"]?.stringValue,
                  let raw = request.payload["event"] else { return nil }
            let event = try DSHSessionEvent(json: raw)
            switch event.type {
            case "user/message":
                let text = textContent(event.data["content"])
                // Slash commands (e.g. /permission) are not real user messages; skip them.
                guard !text.hasPrefix("/") else { return nil }
                return .userCommitted(
                    sessionID: sessionID,
                    requestID: event.data["source"]?["rpcId"]?.stringValue,
                    text: text.nilIfEmpty
                )
            case "assistant/chunk":
                guard let chunk = event.data["chunk"], let text = chunk["text"]?.stringValue else { return nil }
                switch chunk["type"]?.stringValue {
                case "text-delta": return .assistantDelta(
                    sessionID: sessionID,
                    messageKey: ConversationProjector.optionalStepKey(event.data),
                    text: text,
                    reasoning: false
                )
                case "reasoning-delta": return .assistantDelta(
                    sessionID: sessionID,
                    messageKey: ConversationProjector.optionalStepKey(event.data),
                    text: text,
                    reasoning: true
                )
                default: return nil
                }
            case "assistant/message":
                let message = event.data["message"] ?? event.data
                let content = splitContent(message["content"])
                return .assistantComplete(
                    sessionID: sessionID,
                    messageKey: ConversationProjector.optionalStepKey(event.data),
                    text: content.text,
                    reasoning: content.reasoning,
                    attachments: content.attachments
                )
            case "tool/call":
                return .toolStarted(
                    sessionID: sessionID,
                    id: event.data["callId"]?.stringValue ?? UUID().uuidString,
                    name: event.data["name"]?.stringValue ?? "工具",
                    detail: toolCommand(from: event.data["arguments"]?.stringValue)
                )
            case "tool/result":
                let message = event.data["message"] ?? event.data
                return .toolCompleted(
                    sessionID: sessionID,
                    id: message["source"]?["callId"]?.stringValue ?? event.data["callId"]?.stringValue ?? "",
                    name: nil
                )
            case "turn/start": return .running(sessionID: sessionID, value: true)
            case "turn/end": return .running(sessionID: sessionID, value: false)
            case "permission/preset":
                if let preset = event.data["preset"]?.stringValue {
                    return .permissionChanged(sessionID: sessionID, preset: preset)
                }
                return nil
            default: return nil
            }
        case "session/projection":
            guard let sessionID = request.payload["sessionId"]?.stringValue,
                  let key = request.payload["key"]?.stringValue,
                  let value = request.payload["value"] else { return nil }
            if key == "title", let title = value.stringValue {
                return .title(sessionID: sessionID, value: title)
            }
            // tokenUsage / contextPressure are session-level metrics projections.
            if key == "tokenUsage" || key == "contextPressure",
               let metrics = AgentSessionMetrics(json: .object([key: value])) {
                return .sessionMetrics(sessionID: sessionID, metrics: metrics)
            }
            return nil
        case "stream/error":
            return .failure(request.payload["message"]?.stringValue ?? "实时连接发生错误")
        default:
            return nil
        }
    }

    private static func agentSession(_ session: DSHSessionSummary) -> AgentSessionSummary {
        AgentSessionSummary(
            id: session.id,
            title: session.title,
            updatedAt: session.updatedAt,
            isRunning: session.isRunning,
            isBlank: session.isBlank,
            workingDirectory: session.workingDirectory
        )
    }

    private static func runningState(from events: [DSHSessionEvent], fallback: Bool) -> Bool {
        guard let last = events.last(where: { $0.type == "turn/start" || $0.type == "turn/end" }) else {
            return fallback
        }
        return last.type == "turn/start"
    }

    private static func textContent(_ value: JSONValue?) -> String {
        splitContent(value).text
    }

    private static func splitContent(_ value: JSONValue?) -> (text: String, reasoning: String, attachments: [MessageAttachment]) {
        var texts: [String] = []
        var reasoning: [String] = []
        var attachments: [MessageAttachment] = []
        for block in value?.arrayValue ?? [] {
            let type = block["type"]?.stringValue
            if type == "text", let text = block["text"]?.stringValue, !text.isEmpty {
                texts.append(text)
            } else if type == "reasoning", let text = block["text"]?.stringValue, !text.isEmpty {
                reasoning.append(text)
            } else if type == "image" {
                let att = block["attachment"]?.objectValue
                func field(_ key: String) -> JSONValue? {
                    if let att, let v = att[key] { return v }
                    return block[key]
                }
                let attachmentId = field("attachmentId")?.stringValue
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
                attachments.append(MessageAttachment(
                    id: id,
                    kind: .image,
                    name: name,
                    size: size,
                    mimeType: mediaType,
                    attachmentId: attachmentId,
                    base64Data: base64Data
                ))
            } else if type == "file" {
                let att = block["attachment"]?.objectValue
                func field(_ key: String) -> JSONValue? {
                    if let att, let v = att[key] { return v }
                    return block[key]
                }
                let attachmentId = field("attachmentId")?.stringValue
                let rawId = block["id"]?.stringValue
                let id = attachmentId ?? rawId ?? UUID().uuidString
                let name = field("name")?.stringValue ?? "file"
                let size = Int64(field("bytes")?.intValue ?? field("size")?.intValue ?? 0)
                attachments.append(MessageAttachment(
                    id: id,
                    kind: .file,
                    name: name,
                    size: size,
                    mimeType: field("mediaType")?.stringValue,
                    attachmentId: attachmentId
                ))
            }
        }
        return (
            texts.joined(separator: "\n\n"),
            reasoning.joined(separator: "\n\n"),
            attachments
        )
    }

    private static func toolCommand(from arguments: String?) -> String? {
        guard let arguments, let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["command"] as? String) ?? (object["cmd"] as? String)
    }
}
