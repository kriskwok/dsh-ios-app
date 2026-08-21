import Foundation

final class HermesAgentGateway: AgentGateway, @unchecked Sendable {
    private let client: HermesRPCClient

    init(profile: ServerProfile, password: String) {
        client = HermesRPCClient(profile: profile, password: password)
    }

    func connect() async throws {
        try await client.connect()
    }

    func navigation() async throws -> AgentNavigationSnapshot {
        try await connect()
        let list = try await client.call(method: "session.list", params: ["limit": .number(500)])
        var sessionsByID: [String: AgentSessionSummary] = [:]
        for raw in list["sessions"]?.arrayValue ?? [] {
            if let session = Self.session(from: raw) { sessionsByID[session.id] = session }
        }

        var workspaces: [AgentWorkspace] = []
        var archivedIDs: Set<String> = []
        if let tree = try? await client.call(method: "projects.tree", params: ["preview_limit": .number(10)]) {
            for project in tree["projects"]?.arrayValue ?? [] {
                guard let id = project["id"]?.stringValue,
                      project["isNoProject"]?.boolValue != true,
                      project["archived"]?.boolValue != true else { continue }
                let detail = try? await client.call(
                    method: "projects.project_sessions",
                    params: ["project_id": .string(id), "session_limit": .number(5_000)]
                )
                let hydrated = detail?["project"] ?? project
                let rawSessions = Self.projectSessions(hydrated)
                for raw in rawSessions {
                    if var session = Self.session(from: raw) {
                        if session.source == nil {
                            session.source = sessionsByID[session.id]?.source
                        }
                        sessionsByID[session.id] = session
                        if raw["archived"]?.boolValue == true { archivedIDs.insert(session.id) }
                    }
                }
                let sessionIDs = rawSessions.compactMap { $0["id"]?.stringValue }
                let path = hydrated["path"]?.stringValue
                    ?? hydrated["repos"]?.arrayValue?.first?["path"]?.stringValue
                    ?? ""
                workspaces.append(AgentWorkspace(
                    id: id,
                    path: path,
                    title: hydrated["label"]?.stringValue ?? id,
                    sessionIDs: sessionIDs
                ))
            }
        }

        // Coding agent sessions (created via CLI/desktop with Codex etc.)
        // are grouped separately, inserted second-to-last.
        let codingAgentSessions = sessionsByID.values.filter { session in
            session.source == "cli"
        }
        if !codingAgentSessions.isEmpty {
            let caWorkspace = AgentWorkspace(
                id: "__coding_agent__",
                path: "",
                title: "CODING AGENT",
                sessionIDs: codingAgentSessions.map(\.id)
            )
            if workspaces.count >= 1 {
                workspaces.insert(caWorkspace, at: max(workspaces.count - 1, 0))
            } else {
                workspaces.append(caWorkspace)
            }
        }

        return AgentNavigationSnapshot(
            sessions: sessionsByID.values.sorted { $0.updatedAt > $1.updatedAt },
            workspaces: workspaces,
            archivedSessionIDs: archivedIDs
        )
    }

    func openSession(_ session: AgentSessionSummary) async throws -> AgentConversationContext {
        try await connect()
        let result = try await client.call(
            method: "session.resume",
            params: ["session_id": .string(session.id), "cols": .number(100)]
        )
        guard let runtimeID = result["session_id"]?.stringValue else {
            throw HermesClientError.invalidResponse("恢复会话缺少 session_id")
        }
        return AgentConversationContext(
            runtimeSessionID: runtimeID,
            session: session,
            messages: Self.messages(from: result["messages"]),
            title: result["info"]?["title"]?.stringValue?.nilIfEmpty
                ?? result["title"]?.stringValue?.nilIfEmpty
                ?? session.title,
            isRunning: result["running"]?.boolValue ?? false,
            currentModel: Self.extractModel(from: result)
        )
    }

    func createSession(in workspace: AgentWorkspace?) async throws -> AgentConversationContext {
        try await connect()
        var params: [String: JSONValue] = ["source": .string("ios"), "cols": .number(100)]
        if let path = workspace?.path, !path.isEmpty { params["cwd"] = .string(path) }
        let result = try await client.call(method: "session.create", params: params)
        guard let runtimeID = result["session_id"]?.stringValue else {
            throw HermesClientError.invalidResponse("创建会话缺少 session_id")
        }
        let storedID = result["stored_session_id"]?.stringValue ?? runtimeID
        let session = AgentSessionSummary(
            id: storedID,
            isBlank: true,
            workingDirectory: result["info"]?["cwd"]?.stringValue ?? workspace?.path,
            source: "ios"
        )
        return AgentConversationContext(
            runtimeSessionID: runtimeID,
            session: session,
            messages: Self.messages(from: result["messages"]),
            title: "新对话",
            isRunning: false,
            currentModel: Self.extractModel(from: result)
        )
    }

    private static func extractModel(from result: JSONValue) -> AgentModelSelection? {
        let info = result["info"] ?? .object([:])
        let model = result["model"]?.stringValue?.nilIfEmpty
            ?? info["model"]?.stringValue?.nilIfEmpty
        let provider = result["provider"]?.stringValue?.nilIfEmpty
            ?? info["provider"]?.stringValue?.nilIfEmpty
        guard let model, !model.isEmpty else { return nil }
        return AgentModelSelection(
            providerID: provider ?? "",
            modelID: model,
            reasoningLevel: nil
        )
    }

    func send(text: String, sessionID: String, requestID: String) async throws {
        _ = try await client.call(
            method: "prompt.submit",
            params: ["session_id": .string(sessionID), "text": .string(text)]
        )
    }

    func cancel(sessionID: String) async throws {
        _ = try await client.call(method: "session.interrupt", params: ["session_id": .string(sessionID)])
    }

    func respond(to approval: AgentApprovalRequest, choice: AgentApprovalChoice) async throws {
        guard approval.choices.contains(choice) else {
            throw HermesClientError.invalidResponse("该审批选项不可用")
        }
        let result = try await client.call(
            method: "approval.respond",
            params: [
                "session_id": .string(approval.sessionID),
                "choice": .string(choice.rawValue)
            ]
        )
        if result["resolved"]?.boolValue == false {
            throw HermesClientError.invalidResponse("审批已失效或已由其他客户端处理")
        }
    }

    func events() -> AsyncThrowingStream<AgentGatewayEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let events = await client.events()
                do {
                    for try await event in events {
                        continuation.yield(.connected)
                        for mapped in Self.map(event) { continuation.yield(mapped) }
                    }
                    continuation.finish()
                } catch {
                    if !Task.isCancelled { continuation.finish(throwing: error) }
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func close() {
        Task { await client.close() }
    }

    private static let hiddenProviderSlugs: Set<String> = ["nous_portal", "nous-portal", "nousportal"]
    private static let hiddenProviderNames: Set<String> = ["nous portal", "mixture of agents"]

    func fetchModels(sessionID: String) async throws -> AgentModelCatalog {
        try await client.connect()
        let result = try await client.call(
            method: "model.options",
            params: ["session_id": .string(sessionID)]
        )
        let currentProvider = result["provider"]?.stringValue ?? ""
        let currentModel = result["model"]?.stringValue ?? ""


        let groups: [AgentModelGroup] = (result["providers"]?.arrayValue ?? []).compactMap { raw in
            guard let slug = raw["slug"]?.stringValue, !slug.isEmpty else { return nil }
            if Self.hiddenProviderSlugs.contains(slug) { return nil }
            let name = raw["name"]?.stringValue ?? slug
            let lowerName = name.lowercased()
            if Self.hiddenProviderNames.contains(where: { lowerName.contains($0) }) { return nil }
            let isUserDefined = raw["is_user_defined"]?.boolValue ?? false
            var modelIDs = raw["models"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            if lowerName.contains("opencode zen") {
                modelIDs = modelIDs.filter { $0.lowercased().contains("free") }
            }
            guard !modelIDs.isEmpty else { return nil }
            let models = modelIDs.map { modelID in
                AgentModel(
                    id: modelID,
                    name: modelID,
                    providerID: slug,
                    providerName: name,
                    isOfficial: !isUserDefined,
                    description: nil,
                    reasoningLevels: []
                )
            }
            return AgentModelGroup(id: slug, name: name, isOfficial: !isUserDefined, models: models)
        }
        let current: AgentModelSelection? = {
            guard !currentProvider.isEmpty, !currentModel.isEmpty else { return nil }
            return AgentModelSelection(providerID: currentProvider, modelID: currentModel, reasoningLevel: nil)
        }()
        return AgentModelCatalog(groups: groups, currentModel: current, currentReasoningLevel: nil, reasoningLevels: nil, supportsReasoningLevel: false)
    }

    func selectModel(_ selection: AgentModelSelection, sessionID: String) async throws -> AgentModelSelection? {
        let command = "/model \(selection.modelID) --provider \(selection.providerID) --session"
        _ = try? await client.call(
            method: "slash.exec",
            params: ["session_id": .string(sessionID), "command": .string(command)]
        )
        return selection
    }

    static func map(_ event: HermesGatewayEvent) -> [AgentGatewayEvent] {
        guard let sessionID = event.sessionID else {
            return event.type == "error"
                ? [.failure(event.payload["message"]?.stringValue ?? "Hermes 返回错误")]
                : []
        }
        switch event.type {
        case "message.delta":
            return [.assistantDelta(sessionID: sessionID, messageKey: nil, text: event.payload["text"]?.stringValue ?? "", reasoning: false)]
        case "reasoning.delta", "thinking.delta":
            return [.assistantDelta(sessionID: sessionID, messageKey: nil, text: event.payload["text"]?.stringValue ?? "", reasoning: true)]
        case "message.start":
            return [.running(sessionID: sessionID, value: true)]
        case "message.complete":
            return [.assistantComplete(
                sessionID: sessionID,
                messageKey: nil,
                text: event.payload["text"]?.stringValue ?? "",
                reasoning: event.payload["reasoning"]?.stringValue ?? ""
            )]
        case "tool.start":
            return [.toolStarted(
                sessionID: sessionID,
                id: event.payload["tool_id"]?.stringValue ?? UUID().uuidString,
                name: event.payload["name"]?.stringValue ?? "工具",
                detail: event.payload["command"]?.stringValue
            )]
        case "tool.complete":
            return [.toolCompleted(
                sessionID: sessionID,
                id: event.payload["tool_id"]?.stringValue ?? "",
                name: event.payload["name"]?.stringValue
            )]
        case "session.info":
            var output: [AgentGatewayEvent] = []
            if let running = event.payload["running"]?.boolValue {
                output.append(.running(sessionID: sessionID, value: running))
            }
            if let title = event.payload["title"]?.stringValue, !title.isEmpty {
                output.append(.title(sessionID: sessionID, value: title))
            }
            return output
        case "status.update":
            let kind = event.payload["kind"]?.stringValue
            if kind == "running" || kind == "thinking" { return [.running(sessionID: sessionID, value: true)] }
            if kind == "idle" || kind == "complete" { return [.running(sessionID: sessionID, value: false)] }
            return []
        case "approval.request":
            let choices = approvalChoices(from: event.payload)
            let toolName = event.payload["tool_name"]?.stringValue
                ?? event.payload["name"]?.stringValue
                ?? "远程工具"
            return [.approvalRequested(AgentApprovalRequest(
                id: "hermes-\(sessionID)",
                sessionID: sessionID,
                responseToken: nil,
                toolName: toolName,
                description: event.payload["description"]?.stringValue
                    ?? "\(toolName) 请求执行需要确认的操作",
                command: event.payload["command"]?.stringValue,
                callID: event.payload["tool_id"]?.stringValue,
                choices: choices,
                isSmartDenied: event.payload["smart_denied"]?.boolValue ?? false,
                waitsForResolutionEvent: false
            ))]
        case "error":
            return [.failure(event.payload["message"]?.stringValue ?? "Hermes 返回错误")]
        default:
            return []
        }
    }

    static func session(from value: JSONValue) -> AgentSessionSummary? {
        guard let id = value["id"]?.stringValue else { return nil }
        let timestamp = value["last_active"]?.doubleValue ?? value["started_at"]?.doubleValue ?? Date().timeIntervalSince1970
        return AgentSessionSummary(
            id: id,
            title: value["title"]?.stringValue?.nilIfEmpty ?? "新对话",
            updatedAt: Date(timeIntervalSince1970: timestamp),
            isRunning: false,
            isBlank: (value["message_count"]?.intValue ?? 1) == 0,
            workingDirectory: value["cwd"]?.stringValue,
            source: value["source"]?.stringValue?.nilIfEmpty
        )
    }

    static func approvalChoices(from payload: JSONValue) -> [AgentApprovalChoice] {
        let explicit = payload["choices"]?.arrayValue?
            .compactMap(\.stringValue)
            .compactMap(AgentApprovalChoice.init(rawValue:)) ?? []
        if !explicit.isEmpty { return explicit }
        if payload["smart_denied"]?.boolValue == true { return [.once, .deny] }
        if payload["allow_permanent"]?.boolValue == false { return [.once, .session, .deny] }
        return [.once, .session, .always, .deny]
    }

    static func projectSessions(_ project: JSONValue) -> [JSONValue] {
        var output: [JSONValue] = []
        for repo in project["repos"]?.arrayValue ?? [] {
            for group in repo["groups"]?.arrayValue ?? [] {
                output.append(contentsOf: group["sessions"]?.arrayValue ?? [])
            }
        }
        return output
    }

    static func messages(from value: JSONValue?) -> [ConversationMessage] {
        var output: [ConversationMessage] = []
        for (index, raw) in (value?.arrayValue ?? []).enumerated() {
            let role = raw["role"]?.stringValue ?? ""
            let text = raw["text"]?.stringValue ?? messageText(raw["content"])
            let reasoning = role == "assistant" ? reasoningText(raw) : ""
            guard !text.isEmpty || !reasoning.isEmpty || role == "tool" else { continue }
            switch role {
            case "user":
                output.append(message(
                    id: "hermes-user-\(index)", role: .user, text: text,
                    reasoning: "", index: index, raw: raw
                ))
            case "assistant":
                output.append(message(
                    id: "hermes-assistant-\(index)", role: .assistant, text: text,
                    reasoning: reasoning, index: index, raw: raw
                ))
            case "tool":
                let name = raw["name"]?.stringValue ?? raw["tool_name"]?.stringValue ?? "工具"
                output.append(message(
                    id: "hermes-tool-\(index)", role: .activity, text: "已使用 \(name)",
                    reasoning: "", index: index, raw: raw
                ))
            default:
                continue
            }
        }
        return output
    }

    private static func message(
        id: String,
        role: ConversationMessage.Role,
        text: String,
        reasoning: String,
        index: Int,
        raw: JSONValue
    ) -> ConversationMessage {
        ConversationMessage(
            id: id,
            role: role,
            text: text,
            reasoning: reasoning,
            timestamp: Date(timeIntervalSince1970: raw["timestamp"]?.doubleValue ?? Date().timeIntervalSince1970),
            sequence: index,
            isStreaming: false,
            isPending: false
        )
    }

    private static func messageText(_ value: JSONValue?) -> String {
        if let text = value?.stringValue { return text }
        return (value?.arrayValue ?? []).compactMap { part in
            part["text"]?.stringValue ?? part["content"]?.stringValue
        }.joined(separator: "\n\n")
    }

    private static func reasoningText(_ value: JSONValue) -> String {
        for key in ["reasoning", "reasoning_content"] {
            if let text = value[key]?.stringValue, !text.isEmpty { return text }
        }
        return (value["reasoning_details"]?.arrayValue ?? []).compactMap {
            $0["text"]?.stringValue ?? $0["content"]?.stringValue
        }.joined(separator: "\n\n")
    }
}


