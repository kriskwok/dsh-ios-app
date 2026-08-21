import Foundation

final class CodexAgentGateway: AgentGateway, @unchecked Sendable {
    static let defaultWorkspacePath = "/root/Documents/Codex"

    private let client: CodexRPCClient
    private let stateLock = NSLock()
    private var threadStates: [String: CodexThreadState] = [:]
    private var storedModel: AgentModelSelection?
    private var responseContexts: [String: CodexResponseContext] = [:]
    private var eventSink: CodexEventSink?

    init(profile: ServerProfile, password: String) {
        client = CodexRPCClient(profile: profile, password: password)
        client.setServerRequestHandler { [weak self] request in
            guard let self else { return nil }
            self.remember(request)
            return Self.responseResult(for: request)
        }
    }

    func connect() async throws {
        try await client.connect()
    }

    func navigation() async throws -> AgentNavigationSnapshot {
        try await connect()
        var sessions: [AgentSessionSummary] = []
        var cursor: String?
        repeat {
            var params: [String: JSONValue] = [
                "limit": .number(500),
                "archived": .bool(false),
                "sortKey": .string("updated_at"),
                "sortDirection": .string("desc"),
                "sourceKinds": .array([.string("exec"), .string("vscode")]),
                "modelProviders": .array([.string("custom"), .string("openai")])
            ]
            if let cursor, !cursor.isEmpty {
                params["cursor"] = .string(cursor)
            }
            let result = try await client.call(method: "thread/list", params: params)
            for raw in result["data"]?.arrayValue ?? [] {
                if let session = Self.threadSummary(from: raw) {
                    sessions.append(session)
                }
            }
            cursor = result["nextCursor"]?.stringValue
        } while cursor != nil && !cursor!.isEmpty

        let workspaces = Self.workspaces(from: sessions)

        return AgentNavigationSnapshot(
            sessions: sessions,
            workspaces: workspaces,
            archivedSessionIDs: []
        )
    }

    static func workspaces(from sessions: [AgentSessionSummary]) -> [AgentWorkspace] {
        let cwdGroups = Dictionary(grouping: sessions, by: { $0.workingDirectory ?? "" })
        var result = cwdGroups
            .filter { !$0.key.isEmpty }
            .map { path, grouped in
                AgentWorkspace(
                    id: path,
                    path: path,
                    title: Self.workspaceTitle(from: path),
                    sessionIDs: grouped.map(\.id)
                )
            }
            .sorted { lhs, rhs in
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        if !result.contains(where: { $0.path == Self.defaultWorkspacePath }) {
            result.append(AgentWorkspace(
                id: Self.defaultWorkspacePath,
                path: Self.defaultWorkspacePath,
                title: Self.workspaceTitle(from: Self.defaultWorkspacePath),
                sessionIDs: []
            ))
            result.sort { lhs, rhs in
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
        return result
    }

    func openSession(_ session: AgentSessionSummary) async throws -> AgentConversationContext {
        try await connect()
        let resume = try await client.call(method: "thread/resume", params: [
            "threadId": .string(session.id),
            "cwd": .string(session.workingDirectory ?? "")
        ])
        let threadID = session.id
        let read = try await client.call(method: "thread/read", params: [
            "threadId": .string(threadID),
            "includeTurns": .bool(true)
        ])
        let thread = read["thread"] ?? resume["thread"] ?? .object([:])
        let messages = Self.messages(from: thread["turns"])
        let model = Self.modelSelection(from: thread, resume: resume)
        if let model {
            setStoredModel(model)
        }
        return AgentConversationContext(
            runtimeSessionID: threadID,
            session: Self.threadSummary(from: thread) ?? session,
            messages: messages,
            title: thread["name"]?.stringValue?.nilIfEmpty ?? session.title,
            isRunning: Self.isRunning(thread["status"]),
            currentModel: model
        )
    }

    func createSession(in workspace: AgentWorkspace?) async throws -> AgentConversationContext {
        try await connect()
        var params: [String: JSONValue] = [
            "sandbox": .string("workspace-write"),
            "approvalPolicy": .string("on-request"),
            "sessionStartSource": .string("startup"),
            "threadSource": .string("appServer")
        ]
        if let path = workspace?.path, !path.isEmpty {
            params["cwd"] = .string(path)
        }
        if let model = storedModelSelection() {
            params["model"] = .string(model.modelID)
            if !model.providerID.isEmpty {
                params["modelProvider"] = .string(model.providerID)
            }
        }
        let result = try await client.call(method: "thread/start", params: params)
        guard let thread = result["thread"] else {
            throw CodexClientError.invalidResponse("创建会话缺少 thread")
        }
        let threadID = thread["id"]?.stringValue ?? ""
        guard !threadID.isEmpty else {
            throw CodexClientError.invalidResponse("创建会话缺少 thread id")
        }
        let session = Self.threadSummary(from: thread) ?? AgentSessionSummary(id: threadID, isBlank: true)
        let model = Self.modelSelection(from: thread, resume: result)
        if let model {
            setStoredModel(model)
        }
        return AgentConversationContext(
            runtimeSessionID: threadID,
            session: session,
            messages: [],
            title: "新对话",
            isRunning: false,
            currentModel: model
        )
    }

    func send(text: String, sessionID: String, requestID: String) async throws {
        try await connect()
        var params: [String: JSONValue] = [
            "threadId": .string(sessionID),
            "input": .array([.object([
                "type": .string("text"),
                "text": .string(text)
            ])]),
            "clientUserMessageId": .string(requestID)
        ]
        if let model = storedModelSelection() {
            params["model"] = .string(model.modelID)
            if !model.providerID.isEmpty {
                params["modelProvider"] = .string(model.providerID)
            }
            if let effort = model.reasoningLevel {
                params["effort"] = .string(effort.rawValue)
            }
        }
        let result = try await client.call(method: "turn/start", params: params)
        if let turn = result["turn"], let turnID = turn["id"]?.stringValue {
            state(for: sessionID).activeTurnID = turnID
        }
    }

    func cancel(sessionID: String) async throws {
        try await connect()
        let turnID = state(for: sessionID).activeTurnID
        _ = try? await client.call(method: "turn/interrupt", params: [
            "threadId": .string(sessionID),
            "turnId": .string(turnID)
        ])
    }

    func respond(to approval: AgentApprovalRequest, choice: AgentApprovalChoice) async throws {
        guard let token = approval.responseToken else {
            throw CodexClientError.invalidResponse("审批响应缺少请求标识")
        }
        guard let id = tokenAsJSONValue(token) else {
            throw CodexClientError.invalidResponse("审批请求标识无效")
        }
        let context = responseContexts[token] ?? CodexResponseContext(kind: .commandApproval, params: .object([:]))
        let result = Self.responseResult(
            kind: context.kind,
            choice: choice,
            params: context.params
        )
        await client.respondToServerRequest(id: id, result: result)
    }

    func respond(to question: AgentQuestionRequest, answers: [AgentQuestionAnswer]) async throws {
        guard let token = question.responseToken,
              let id = tokenAsJSONValue(token) else {
            throw CodexClientError.invalidResponse("提问请求标识无效")
        }
        let answersObject = Dictionary(uniqueKeysWithValues: answers.map { answer in
            var values = answer.selected
            if let custom = answer.custom, !custom.isEmpty { values.append(custom) }
            return (answer.id, JSONValue.array(values.map(JSONValue.string)))
        })
        await client.respondToServerRequest(id: id, result: .object(["answers": .object(answersObject)]))
    }

    func respondCancelled(to question: AgentQuestionRequest) async throws {
        guard let token = question.responseToken,
              let id = tokenAsJSONValue(token) else {
            throw CodexClientError.invalidResponse("提问请求标识无效")
        }
        await client.respondToServerRequest(id: id, result: .object([
            "answers": .object([:])
        ]))
    }

    func events() -> AsyncThrowingStream<AgentGatewayEvent, Error> {
        AsyncThrowingStream { continuation in
            let sink = CodexEventSink(continuation: continuation)
            eventSink = sink
            sink.yield(.connected)
            let task = Task {
                do {
                    for try await event in await client.events() {
                        switch event {
                        case .failure(let message):
                            sink.yield(.failure(message))
                        case .notification(let notification):
                            let threadID = notification.params["threadId"]?.stringValue ?? ""
                            let threadState = self.state(for: threadID)
                            let requestKind: (String) -> CodexServerRequestKind? = { requestID in
                                self.responseKind(for: requestID)
                            }
                            for mapped in Self.map(
                                notification,
                                threadState: threadState,
                                requestKindFor: requestKind
                            ) {
                                sink.yield(mapped)
                            }
                        }
                    }
                    sink.finish()
                } catch {
                    if !Task.isCancelled { sink.finish(throwing: error) }
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                self.eventSink = nil
            }
        }
    }

    func close() {
        Task { await client.close() }
    }

    func fetchModels(sessionID: String) async throws -> AgentModelCatalog {
        try await connect()
        let stored = storedModelSelection() ?? state(for: sessionID).model
        var current = stored
        let config = try? await client.call(method: "config/read", params: [String: JSONValue]())
        let configValue = config?["config"]
        let configuredProvider = configValue?["model_provider"]?.stringValue?.nilIfEmpty ?? ""
        let configuredModel = configValue?["model"]?.stringValue?.nilIfEmpty
        let configuredEffort = configValue?["model_reasoning_effort"]?.stringValue.flatMap(ReasoningLevel.init)
        if current == nil, let configuredModel {
            let selection = AgentModelSelection(
                providerID: configuredProvider.nilIfEmpty ?? Self.providerID(for: configuredModel),
                modelID: configuredModel,
                reasoningLevel: configuredEffort
            )
            setStoredModel(selection)
            state(for: sessionID).model = selection
            current = selection
        }
        let configuredProviderName = configValue?["model_providers"]?[configuredProvider]?["name"]?.stringValue?.nilIfEmpty ?? ""

        let result = try await client.call(method: "model/list", params: [
            "includeHidden": .bool(false)
        ])
        var models: [AgentModel] = []
        for raw in result["data"]?.arrayValue ?? [] {
            let modelID = raw["id"]?.stringValue ?? ""
            guard !modelID.isEmpty else { continue }
            let displayName = raw["displayName"]?.stringValue?.nilIfEmpty ?? modelID
            let provider = configuredProvider.nilIfEmpty ?? Self.providerID(for: modelID)
            let modelLevels = (raw["supportedReasoningEfforts"]?.arrayValue ?? []).compactMap {
                $0["reasoningEffort"]?.stringValue.flatMap(ReasoningLevel.init)
            }
            let defaultLevel = raw["defaultReasoningEffort"]?.stringValue.flatMap(ReasoningLevel.init)
            models.append(AgentModel(
                id: modelID,
                name: displayName,
                providerID: provider,
                providerName: configuredProviderName.nilIfEmpty ?? (provider == "openai" ? "OpenAI" : "Codex 模型"),
                isOfficial: provider == "openai",
                description: raw["description"]?.stringValue,
                reasoningLevels: modelLevels,
                defaultReasoningLevel: defaultLevel
            ))
        }
        let group = AgentModelGroup(
            id: configuredProvider.nilIfEmpty ?? "codex",
            name: configuredProviderName.nilIfEmpty ?? "Codex 模型",
            isOfficial: configuredProvider == "openai",
            models: models
        )
        return AgentModelCatalog(
            groups: models.isEmpty ? [] : [group],
            currentModel: current,
            currentReasoningLevel: current?.reasoningLevel,
            reasoningLevels: nil,
            supportsReasoningLevel: true
        )
    }

    func selectModel(_ selection: AgentModelSelection, sessionID: String) async throws -> AgentModelSelection? {
        setStoredModel(selection)
        state(for: sessionID).model = selection
        if !state(for: sessionID).activeTurnID.isEmpty {
            _ = try? await client.call(method: "turn/steer", params: [
                "threadId": .string(sessionID),
                "model": .string(selection.modelID),
                "modelProvider": .string(selection.providerID),
                "effort": selection.reasoningLevel.map { JSONValue.string($0.rawValue) } ?? .null
            ])
        }
        return selection
    }

    private func state(for threadID: String) -> CodexThreadState {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let existing = threadStates[threadID] { return existing }
        let created = CodexThreadState()
        threadStates[threadID] = created
        return created
    }

    private func setStoredModel(_ model: AgentModelSelection) {
        stateLock.lock()
        storedModel = model
        stateLock.unlock()
    }

    private func storedModelSelection() -> AgentModelSelection? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedModel
    }

    private func remember(_ request: CodexServerRequest) {
        guard let kind = request.kind else { return }
        stateLock.lock()
        responseContexts[request.idKey] = CodexResponseContext(kind: kind, params: request.params)
        stateLock.unlock()

        let event: AgentGatewayEvent?
        switch kind {
        case .commandApproval, .fileChangeApproval, .permissionsApproval:
            event = .approvalRequested(Self.approvalRequest(from: request))
        case .userInput:
            event = .questionRequested(Self.questionRequest(from: request))
        }
        if let event {
            eventSink?.yield(event)
        }
    }

    private func responseKind(for requestID: String) -> CodexServerRequestKind? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return responseContexts[requestID]?.kind
    }

    // MARK: Mapping

    static func responseResult(for request: CodexServerRequest) -> JSONValue? {
        guard let kind = request.kind else { return nil }
        switch kind {
        case .commandApproval, .fileChangeApproval, .permissionsApproval:
            return nil
        case .userInput:
            return responseResult(kind: kind, choice: .once, params: request.params)
        }
    }

    static func responseResult(kind: CodexServerRequestKind, choice: AgentApprovalChoice, params: JSONValue) -> JSONValue {
        switch kind {
        case .commandApproval:
            return .object(["decision": decisionValue(choice, params: params)])
        case .fileChangeApproval:
            return .object(["decision": decisionValue(choice, params: params)])
        case .permissionsApproval:
            let scope: String
            switch choice {
            case .session: scope = "session"
            default: scope = "turn"
            }
            return .object([
                "permissions": .object([
                    "id": params["permissions"]?["id"] ?? .string(":workspace")
                ]),
                "scope": .string(scope),
                "strictAutoReview": .bool(choice == .once)
            ])
        case .userInput:
            return .object(["answers": .object([:])])
        }
    }

    static func decisionValue(_ choice: AgentApprovalChoice, params: JSONValue) -> JSONValue {
        switch choice {
        case .once:
            return .string("accept")
        case .session:
            return .string("acceptForSession")
        case .always:
            if let amendment = params["proposedExecpolicyAmendment"]?.arrayValue {
                return .object([
                    "acceptWithExecpolicyAmendment": .object([
                        "execpolicy_amendment": .array(amendment)
                    ])
                ])
            }
            return .string("acceptForSession")
        case .deny:
            return .string("decline")
        }
    }

    static func map(
        _ notification: CodexRPCNotification,
        threadState: CodexThreadState,
        requestKindFor: (String) -> CodexServerRequestKind? = { _ in nil }
    ) -> [AgentGatewayEvent] {
        let params = notification.params
        let threadID = params["threadId"]?.stringValue ?? ""
        switch notification.method {
        case "thread/started", "thread/loaded":
            return []
        case "thread/status/changed":
            let running = statusIsRunning(params["status"])
            threadState.isRunning = running
            if !running {
                threadState.streamingItems.removeAll()
            }
            return [.running(sessionID: threadID, value: running)]
        case "thread/name/updated":
            guard let title = params["threadName"]?.stringValue, !title.isEmpty else { return [] }
            return [.title(sessionID: threadID, value: title)]
        case "turn/started":
            let turnID = params["turn"]?["id"]?.stringValue ?? ""
            threadState.activeTurnID = turnID
            threadState.isRunning = true
            return [.running(sessionID: threadID, value: true)]
        case "turn/completed":
            threadState.isRunning = false
            threadState.streamingItems.removeAll()
            var events: [AgentGatewayEvent] = [.running(sessionID: threadID, value: false)]
            for item in params["turn"]?["items"]?.arrayValue ?? [] {
                let itemID = item["id"]?.stringValue ?? ""
                switch item["type"]?.stringValue {
                case "reasoning":
                    let content = item["content"]?.arrayValue?.compactMap(\.stringValue) ?? []
                    let summary = item["summary"]?.arrayValue?.compactMap(\.stringValue) ?? []
                    if !content.isEmpty || !summary.isEmpty {
                        threadState.reasoningItems[itemID] = content.isEmpty ? summary : content
                    }
                case "agentMessage":
                    let text = item["text"]?.stringValue ?? ""
                    let reasoning = threadState.reasoningItems.removeValue(forKey: itemID)?
                        .joined(separator: "\n")
                        ?? threadState.reasoningItems.values.flatMap { $0 }.joined(separator: "\n")
                    threadState.reasoningItems.removeAll()
                    if !text.isEmpty || !reasoning.isEmpty {
                        events.append(.assistantComplete(
                            sessionID: threadID,
                            messageKey: itemID,
                            text: text,
                            reasoning: reasoning
                        ))
                    }
                default:
                    continue
                }
            }
            return events
        case "item/started":
            return itemEvents(params, threadState: threadState, isStarted: true)
        case "item/completed":
            return itemEvents(params, threadState: threadState, isStarted: false)
        case "item/agentMessage/delta", "agentMessage/delta":
            let itemID = params["itemId"]?.stringValue ?? ""
            let delta = params["delta"]?.stringValue ?? ""
            guard !itemID.isEmpty, !delta.isEmpty else { return [] }
            if threadState.reasoningItems[itemID] != nil {
                threadState.reasoningItems[itemID]?.append(delta)
                return [.assistantDelta(sessionID: threadID, messageKey: itemID, text: delta, reasoning: true)]
            }
            threadState.streamingItems.insert(itemID)
            return [.assistantDelta(sessionID: threadID, messageKey: itemID, text: delta, reasoning: false)]
        case "item/reasoning/textDelta", "item/reasoning/summaryTextDelta":
            let itemID = params["itemId"]?.stringValue ?? ""
            let delta = params["delta"]?.stringValue ?? ""
            guard !itemID.isEmpty, !delta.isEmpty else { return [] }
            threadState.reasoningItems[itemID, default: []].append(delta)
            threadState.streamingItems.insert(itemID)
            return [.assistantDelta(sessionID: threadID, messageKey: itemID, text: delta, reasoning: true)]
        case "item/reasoning/summaryPartAdded":
            return []
        case "serverRequest/resolved":
            let requestID = params["requestId"]?.stringValue
                ?? params["rpcId"]?.stringValue
                ?? ""
            guard !requestID.isEmpty else { return [] }
            switch requestKindFor(requestID) {
            case .commandApproval, .fileChangeApproval, .permissionsApproval:
                return [.approvalResolved(sessionID: threadID, approvalID: requestID, outcome: "resolved")]
            case .userInput:
                return [.questionResolved(sessionID: threadID, questionRpcId: requestID, outcome: "resolved")]
            case nil:
                return []
            }
        case "error":
            return [.failure(params["message"]?.stringValue ?? "Codex 返回错误")]
        default:
            return []
        }
    }

    private static func itemEvents(_ params: JSONValue, threadState: CodexThreadState, isStarted: Bool) -> [AgentGatewayEvent] {
        guard let item = params["item"], let type = item["type"]?.stringValue else { return [] }
        let threadID = params["threadId"]?.stringValue ?? ""
        let itemID = item["id"]?.stringValue ?? UUID().uuidString

        switch type {
        case "userMessage":
            guard !isStarted else { return [] }
            let clientID = item["clientId"]?.stringValue
            let text = userText(from: item["content"])
            return [.userCommitted(sessionID: threadID, requestID: clientID, text: text.nilIfEmpty)]
        case "agentMessage":
            if isStarted {
                threadState.streamingItems.insert(itemID)
                return []
            }
            threadState.streamingItems.remove(itemID)
            let reasoning = joinedReasoning(threadState.reasoningItems)
            return [.assistantComplete(
                sessionID: threadID,
                messageKey: itemID,
                text: item["text"]?.stringValue ?? "",
                reasoning: reasoning
            )]
        case "reasoning":
            let content = item["content"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let summary = item["summary"]?.arrayValue?.compactMap(\.stringValue) ?? []
            threadState.reasoningItems[itemID] = content.isEmpty ? summary : content
            threadState.streamingItems.insert(itemID)
            if isStarted, let text = (content + summary).joined(separator: "\n").nilIfEmpty {
                return [.assistantDelta(sessionID: threadID, messageKey: itemID, text: text, reasoning: true)]
            }
            return []
        case "commandExecution":
            let name = "执行命令"
            let detail = item["command"]?.stringValue
            if isStarted {
                threadState.toolItems[itemID] = name
                return [.toolStarted(sessionID: threadID, id: itemID, name: name, detail: detail)]
            }
            let finalName = threadState.toolItems.removeValue(forKey: itemID) ?? name
            return [.toolCompleted(sessionID: threadID, id: itemID, name: finalName)]
        case "fileChange":
            let name = "修改文件"
            if isStarted {
                threadState.toolItems[itemID] = name
                return [.toolStarted(sessionID: threadID, id: itemID, name: name, detail: nil)]
            }
            let finalName = threadState.toolItems.removeValue(forKey: itemID) ?? name
            return [.toolCompleted(sessionID: threadID, id: itemID, name: finalName)]
        case "mcpToolCall", "dynamicToolCall":
            let name = "\(item["server"]?.stringValue ?? item["tool"]?.stringValue ?? "工具")"
            let toolName = "使用 \(name)"
            if isStarted {
                threadState.toolItems[itemID] = toolName
                return [.toolStarted(sessionID: threadID, id: itemID, name: toolName, detail: nil)]
            }
            let finalName = threadState.toolItems.removeValue(forKey: itemID) ?? toolName
            return [.toolCompleted(sessionID: threadID, id: itemID, name: finalName)]
        case "webSearch":
            let name = "联网搜索"
            if isStarted {
                threadState.toolItems[itemID] = name
                return [.toolStarted(sessionID: threadID, id: itemID, name: name, detail: item["query"]?.stringValue)]
            }
            let finalName = threadState.toolItems.removeValue(forKey: itemID) ?? name
            return [.toolCompleted(sessionID: threadID, id: itemID, name: finalName)]
        default:
            return []
        }
    }

    static func threadSummary(from value: JSONValue) -> AgentSessionSummary? {
        guard let id = value["id"]?.stringValue else { return nil }
        let timestamp = value["updatedAt"]?.doubleValue ?? value["recencyAt"]?.doubleValue ?? Date().timeIntervalSince1970
        let preview = value["preview"]?.stringValue ?? ""
        let hasPreview = preview.nilIfEmpty != nil
        return AgentSessionSummary(
            id: id,
            title: value["name"]?.stringValue?.nilIfEmpty ?? preview.nilIfEmpty ?? "新对话",
            updatedAt: Date(timeIntervalSince1970: timestamp),
            isRunning: isRunning(value["status"]),
            isBlank: !hasPreview && value["turns"]?.arrayValue?.isEmpty != false,
            workingDirectory: value["cwd"]?.stringValue,
            source: "appServer",
            modelProvider: value["modelProvider"]?.stringValue
        )
    }

    private static func workspaceTitle(from path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    static func modelSelection(from thread: JSONValue, resume: JSONValue) -> AgentModelSelection? {
        let provider = resume["modelProvider"]?.stringValue
            ?? thread["modelProvider"]?.stringValue
            ?? ""
        let model = resume["model"]?.stringValue
            ?? thread["model"]?.stringValue
            ?? ""
        guard !model.isEmpty else { return nil }
        var reasoning: ReasoningLevel?
        if let effort = resume["reasoningEffort"]?.stringValue ?? thread["reasoningEffort"]?.stringValue {
            reasoning = ReasoningLevel(rawValue: effort)
        }
        return AgentModelSelection(providerID: provider, modelID: model, reasoningLevel: reasoning)
    }

    static func messages(from turns: JSONValue?) -> [ConversationMessage] {
        var output: [ConversationMessage] = []
        var sequence = 0
        var reasoning: [String: String] = [:]
        for turn in turns?.arrayValue ?? [] {
            for item in turn["items"]?.arrayValue ?? [] {
                let itemID = item["id"]?.stringValue ?? "item-\(sequence)"
                switch item["type"]?.stringValue {
                case "userMessage":
                    let text = userText(from: item["content"])
                    guard !text.isEmpty else { continue }
                    output.append(ConversationMessage(
                        id: item["clientId"]?.stringValue ?? "codex-user-\(itemID)",
                        role: .user,
                        text: text,
                        reasoning: "",
                        timestamp: Date(timeIntervalSince1970: item["startedAtMs"]?.doubleValue.map { $0 / 1_000 } ?? Date().timeIntervalSince1970),
                        sequence: sequence,
                        isStreaming: false,
                        isPending: false
                    ))
                    sequence += 1
                case "reasoning":
                    let content = item["content"]?.arrayValue?.compactMap(\.stringValue) ?? []
                    let summary = item["summary"]?.arrayValue?.compactMap(\.stringValue) ?? []
                    let text = (content + summary).joined(separator: "\n")
                    if !text.isEmpty { reasoning[itemID] = text }
                case "agentMessage":
                    let text = item["text"]?.stringValue ?? ""
                    let reasoningText = reasoning.removeValue(forKey: itemID)
                        ?? reasoning.values.joined(separator: "\n")
                    reasoning.removeAll()
                    guard !text.isEmpty || !reasoningText.isEmpty else { continue }
                    output.append(ConversationMessage(
                        id: "codex-assistant-\(itemID)",
                        role: .assistant,
                        text: text,
                        reasoning: reasoningText,
                        timestamp: Date(timeIntervalSince1970: item["startedAtMs"]?.doubleValue.map { $0 / 1_000 } ?? Date().timeIntervalSince1970),
                        sequence: sequence,
                        isStreaming: false,
                        isPending: false
                    ))
                    sequence += 1
                case "commandExecution":
                    output.append(ConversationMessage(
                        id: "codex-tool-\(itemID)",
                        role: .activity,
                        text: item["status"]?.stringValue == "inProgress" ? "正在执行命令" : "已执行命令",
                        reasoning: "",
                        timestamp: Date(timeIntervalSince1970: item["startedAtMs"]?.doubleValue.map { $0 / 1_000 } ?? Date().timeIntervalSince1970),
                        sequence: sequence,
                        isStreaming: item["status"]?.stringValue == "inProgress",
                        isPending: false
                    ))
                    sequence += 1
                case "fileChange":
                    output.append(ConversationMessage(
                        id: "codex-file-\(itemID)",
                        role: .activity,
                        text: item["status"]?.stringValue == "inProgress" ? "正在修改文件" : "已修改文件",
                        reasoning: "",
                        timestamp: Date(timeIntervalSince1970: item["startedAtMs"]?.doubleValue.map { $0 / 1_000 } ?? Date().timeIntervalSince1970),
                        sequence: sequence,
                        isStreaming: item["status"]?.stringValue == "inProgress",
                        isPending: false
                    ))
                    sequence += 1
                case "mcpToolCall", "dynamicToolCall":
                    let toolName = item["server"]?.stringValue
                        ?? item["tool"]?.stringValue
                        ?? "工具"
                    output.append(ConversationMessage(
                        id: "codex-tool-\(itemID)",
                        role: .activity,
                        text: "已使用 \(toolName)",
                        reasoning: "",
                        timestamp: Date(timeIntervalSince1970: item["startedAtMs"]?.doubleValue.map { $0 / 1_000 } ?? Date().timeIntervalSince1970),
                        sequence: sequence,
                        isStreaming: false,
                        isPending: false
                    ))
                    sequence += 1
                case "webSearch":
                    output.append(ConversationMessage(
                        id: "codex-search-\(itemID)",
                        role: .activity,
                        text: "已联网搜索",
                        reasoning: "",
                        timestamp: Date(timeIntervalSince1970: item["startedAtMs"]?.doubleValue.map { $0 / 1_000 } ?? Date().timeIntervalSince1970),
                        sequence: sequence,
                        isStreaming: false,
                        isPending: false
                    ))
                    sequence += 1
                case "imageView":
                    if let path = item["path"]?.stringValue,
                       let url = remoteImageURL(path) {
                        output.append(ConversationMessage(
                            id: "codex-image-\(itemID)",
                            role: .assistant,
                            text: "![图片](\(url.absoluteString))",
                            reasoning: "",
                            timestamp: Date(timeIntervalSince1970: item["startedAtMs"]?.doubleValue.map { $0 / 1_000 } ?? Date().timeIntervalSince1970),
                            sequence: sequence,
                            isStreaming: false,
                            isPending: false
                        ))
                        sequence += 1
                    }
                default:
                    continue
                }
            }
        }
        return output
    }

    private static func remoteImageURL(_ path: String) -> URL? {
        if let url = URL(string: path), url.scheme == "http" || url.scheme == "https" {
            return url
        }
        return nil
    }

    static func userText(from content: JSONValue?) -> String {
        let parts = content?.arrayValue ?? []
        let textParts = parts.compactMap { part -> String? in
            guard part["type"]?.stringValue == "text",
                  let text = part["text"]?.stringValue,
                  !text.isEmpty else { return nil }
            return text
        }
        let images = parts.compactMap { part -> String? in
            guard part["type"]?.stringValue == "image",
                  let url = part["url"]?.stringValue,
                  !url.isEmpty else { return nil }
            return "![图片](\(url))"
        }
        return (textParts + images).joined(separator: "\n\n")
    }

    static func approvalChoices(for request: CodexServerRequest) -> [AgentApprovalChoice] {
        switch request.kind {
        case .fileChangeApproval:
            return [.once, .session, .deny]
        case .permissionsApproval:
            return [.once, .session, .deny]
        default:
            if request.params["proposedExecpolicyAmendment"]?.arrayValue?.isEmpty == false
                || request.params["proposedNetworkPolicyAmendments"]?.arrayValue?.isEmpty == false {
                return [.once, .session, .always, .deny]
            }
            return [.once, .session, .deny]
        }
    }

    static func approvalRequest(from request: CodexServerRequest) -> AgentApprovalRequest {
        let params = request.params
        let approvalID = params["approvalId"]?.stringValue ?? request.idKey
        let command = params["command"]?.stringValue
        let toolName: String
        let description: String
        switch request.kind {
        case .fileChangeApproval:
            toolName = "修改文件"
            description = params["reason"]?.stringValue ?? "Codex 请求修改工作区文件"
        case .permissionsApproval:
            toolName = "权限请求"
            description = params["reason"]?.stringValue ?? "Codex 请求扩展权限"
        default:
            toolName = "执行命令"
            description = params["reason"]?.stringValue
                ?? (command.map { "Codex 请求执行命令：\($0)" } ?? "Codex 请求执行命令")
        }
        return AgentApprovalRequest(
            id: "codex-\(approvalID)",
            sessionID: params["threadId"]?.stringValue ?? "",
            responseToken: request.idKey,
            toolName: toolName,
            description: description,
            command: command,
            callID: params["itemId"]?.stringValue,
            choices: approvalChoices(for: request),
            isSmartDenied: false,
            waitsForResolutionEvent: true
        )
    }

    static func questionRequest(from request: CodexServerRequest) -> AgentQuestionRequest {
        let params = request.params
        let questions: [AgentQuestion] = (params["questions"]?.arrayValue ?? []).enumerated().map { index, raw in
            AgentQuestion(
                id: raw["id"]?.stringValue ?? "question-\(index)",
                question: raw["question"]?.stringValue ?? "请选择",
                detail: nil,
                header: raw["header"]?.stringValue?.nilIfEmpty,
                options: (raw["options"]?.arrayValue ?? []).compactMap { option in
                    guard let label = option["label"]?.stringValue else { return nil }
                    return AgentQuestionOption(
                        id: label,
                        label: label,
                        description: option["description"]?.stringValue
                    )
                },
                multiSelect: false
            )
        }
        return AgentQuestionRequest(
            id: "codex-question-\(request.idKey)",
            sessionID: params["threadId"]?.stringValue ?? "",
            responseToken: request.idKey,
            questions: questions,
            waitsForResolutionEvent: true
        )
    }

    static func isRunning(_ status: JSONValue?) -> Bool {
        status?["type"]?.stringValue == "active"
    }

    private static func statusIsRunning(_ status: JSONValue?) -> Bool {
        isRunning(status)
    }

    private static func joinedReasoning(_ items: [String: [String]]) -> String {
        items.values.flatMap { $0 }.joined(separator: "\n")
    }

    static func providerID(for modelID: String) -> String {
        let lower = modelID.lowercased()
        if lower.hasPrefix("gpt")
            || lower.hasPrefix("o1")
            || lower.hasPrefix("o3")
            || lower.hasPrefix("o4")
            || lower.hasPrefix("codex") {
            return "openai"
        }
        return "openai"
    }

    private func tokenAsJSONValue(_ token: String) -> JSONValue? {
        if let number = Double(token), String(format: "%.0f", number) == token {
            return .number(number)
        }
        return .string(token)
    }
}

final class CodexThreadState: @unchecked Sendable {
    var activeTurnID = ""
    var isRunning = false
    var streamingItems: Set<String> = []
    var toolItems: [String: String] = [:]
    var reasoningItems: [String: [String]] = [:]
    var model: AgentModelSelection?
}

private struct CodexResponseContext: Sendable {
    let kind: CodexServerRequestKind
    let params: JSONValue
}

private final class CodexEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<AgentGatewayEvent, Error>.Continuation?

    init(continuation: AsyncThrowingStream<AgentGatewayEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func yield(_ event: AgentGatewayEvent) {
        lock.lock()
        continuation?.yield(event)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        continuation?.finish()
        continuation = nil
        lock.unlock()
    }

    func finish(throwing error: Error) {
        lock.lock()
        continuation?.finish(throwing: error)
        continuation = nil
        lock.unlock()
    }
}
