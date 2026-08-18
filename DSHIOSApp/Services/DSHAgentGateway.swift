import Foundation

final class DSHAgentGateway: AgentGateway, @unchecked Sendable {
    private let client: DSHAPIClient

    init(profile: ServerProfile, password: String) {
        client = DSHAPIClient(profile: profile, password: password)
    }

    func connect() async throws {}

    func navigation() async throws -> AgentNavigationSnapshot {
        let sessionResult = try await client.call(method: "session.list")
        let rawSessions = sessionResult.value["items"]?.arrayValue ?? []
        let dshSessions = try rawSessions.map(DSHSessionSummary.init(json:))
        let sessions = dshSessions.map(Self.agentSession).sorted { $0.updatedAt > $1.updatedAt }

        do {
            let workspaceResult = try await client.call(method: "workspace.list")
            let list = try DSHWorkspaceList(json: workspaceResult.value)
            return AgentNavigationSnapshot(
                sessions: sessions,
                workspaces: list.items.map {
                    AgentWorkspace(id: $0.id, path: $0.path, title: $0.title, sessionIDs: $0.sessionIDs)
                },
                archivedSessionIDs: list.archivedSessionIDs
            )
        } catch {
            return AgentNavigationSnapshot(sessions: sessions, workspaces: [], archivedSessionIDs: [])
        }
    }

    func openSession(_ session: AgentSessionSummary) async throws -> AgentConversationContext {
        let result = try await client.call(
            method: "session.history",
            payload: ["sessionId": .string(session.id), "maxMessages": .number(80)]
        )
        let history = try DSHHistoryPage(json: result.value)
        var projector = ConversationProjector()
        projector.replace(with: history.events)
        return AgentConversationContext(
            runtimeSessionID: session.id,
            session: session,
            messages: projector.messages(),
            title: history.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? session.title,
            isRunning: Self.runningState(from: history.events, fallback: session.isRunning)
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
            isRunning: false
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
        let groups = (value["groups"]?.arrayValue ?? []).compactMap { rawGroup -> AgentModelGroup? in
            guard let groupID = rawGroup["id"]?.stringValue else { return nil }
            let groupName = rawGroup["name"]?.stringValue ?? groupID
            let isOfficial = rawGroup["official"]?.boolValue ?? false
            let models = (rawGroup["models"]?.arrayValue ?? []).compactMap { rawModel -> AgentModel? in
                guard let modelID = rawModel["id"]?.stringValue else { return nil }
                return AgentModel(
                    id: modelID,
                    name: rawModel["name"]?.stringValue ?? modelID,
                    providerID: groupID,
                    providerName: groupName,
                    isOfficial: isOfficial,
                    description: rawModel["description"]?.stringValue?.nilIfEmpty
                )
            }
            return AgentModelGroup(id: groupID, name: groupName, isOfficial: isOfficial, models: models)
        }
        return AgentModelCatalog(groups: groups, currentModel: current, currentReasoningLevel: reasoningLevel)
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


