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
        // TEMP DEBUG: dump keys and key objects
        for key in (result.value.objectValue ?? [:]).keys.sorted() {
            print("[DEBUG-DSH-HIST] key:", key)
        }
        if let cp = result.value["contextPressure"] { debugPrint("[DEBUG-DSH-HIST] contextPressure:", cp) }
        if let tu = result.value["tokenUsage"] { debugPrint("[DEBUG-DSH-HIST] tokenUsage:", tu) }
        let history = try DSHHistoryPage(json: result.value)
        var projector = ConversationProjector()
        projector.replace(with: history.events)
        return AgentConversationContext(
            runtimeSessionID: session.id,
            session: session,
            messages: projector.messages(),
            title: history.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? session.title,
            isRunning: Self.runningState(from: history.events, fallback: session.isRunning),
            currentModel: nil,
            metrics: AgentSessionMetrics(json: result.value)
        )
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
        _ = try await client.call(
            method: "session.prompt",
            payload: [
                "sessionId": .string(sessionID),
                "mode": .string("queue"),
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                "clientTimeZone": .string(TimeZone.current.identifier)
            ],
            rpcId: requestID
        )
    }

    func cancel(sessionID: String) async throws {
        _ = try await client.call(method: "session.cancel", payload: ["sessionId": .string(sessionID)])
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
                            // Extract usage metrics from assistant/message events
                            if case "session/event" = request.method,
                               request.payload["event"]?["type"]?.stringValue == "assistant/message",
                               let sessionID = request.payload["sessionId"]?.stringValue,
                               let usage = request.payload["event"]?["message"]?["usage"]
                                    ?? request.payload["event"]?["usage"],
                               let metrics = AgentSessionMetrics(json: usage) {
                                continuation.yield(.sessionMetrics(sessionID: sessionID, metrics: metrics))
                            }
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
                print("[DEBUG-DSH-AM] usage:", event.data["usage"] ?? "nil")
                let message = event.data["message"] ?? event.data
                let content = splitContent(message["content"])
                return .assistantComplete(
                    sessionID: sessionID,
                    messageKey: ConversationProjector.optionalStepKey(event.data),
                    text: content.text,
                    reasoning: content.reasoning
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
            default: return nil
            }
        case "session/projection":
            guard request.payload["key"]?.stringValue == "title",
                  let sessionID = request.payload["sessionId"]?.stringValue,
                  let value = request.payload["value"]?.stringValue else { return nil }
            return .title(sessionID: sessionID, value: value)
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

    private static func splitContent(_ value: JSONValue?) -> (text: String, reasoning: String) {
        var texts: [String] = []
        var reasoning: [String] = []
        for block in value?.arrayValue ?? [] {
            guard let text = block["text"]?.stringValue, !text.isEmpty else { continue }
            if block["type"]?.stringValue == "reasoning" {
                reasoning.append(text)
            } else if block["type"]?.stringValue == "text" {
                texts.append(text)
            }
        }
        return (texts.joined(separator: "\n\n"), reasoning.joined(separator: "\n\n"))
    }

    private static func toolCommand(from arguments: String?) -> String? {
        guard let arguments, let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["command"] as? String) ?? (object["cmd"] as? String)
    }
}
