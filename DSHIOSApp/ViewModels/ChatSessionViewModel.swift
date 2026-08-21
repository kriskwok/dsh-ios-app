import Foundation

@MainActor
final class ChatSessionViewModel: ObservableObject {
    @Published private(set) var messages: [ConversationMessage] = []
    @Published var composerText = ""
    @Published private(set) var isLoading: Bool
    @Published private(set) var isRunning: Bool
    @Published private(set) var isConnected = false
    @Published private(set) var isReconnecting = false
    @Published private(set) var isStopping = false
    @Published private(set) var pendingApprovals: [AgentApprovalRequest] = []
    @Published private(set) var respondingApprovalID: String?
    @Published private(set) var pendingQuestions: [AgentQuestionRequest] = []
    @Published private(set) var respondingQuestionID: String?
    @Published var errorMessage: String?
    @Published var title: String
    @Published private(set) var modelCatalog: AgentModelCatalog?
    @Published private(set) var isModelLoading = false
    @Published private(set) var isModelSelecting = false

    let agentName: String
    let agentKind: AgentServerKind

    private var runtimeSessionID: String?
    private var storedSession: AgentSessionSummary?
    private var contextModel: AgentModelSelection?
    private let workspace: AgentWorkspace?
    private let gateway: any AgentGateway
    private let reconnectDelay: @Sendable (Int) -> Duration
    private let onSessionCreated: @MainActor (AgentSessionSummary) -> Void
    private let onPromptAccepted: @MainActor (String) -> Void
    private var eventTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var toolDetails: [String: String] = [:]
    private(set) var hasStarted = false
    private var isFetchingModels = false

    var pendingApproval: AgentApprovalRequest? { pendingApprovals.first }
    var pendingQuestion: AgentQuestionRequest? { pendingQuestions.first }

    init(
        profile: ServerProfile,
        password: String,
        session: AgentSessionSummary?,
        workspace: AgentWorkspace?,
        onSessionCreated: @escaping @MainActor (AgentSessionSummary) -> Void,
        onPromptAccepted: @escaping @MainActor (String) -> Void,
        gateway: (any AgentGateway)? = nil,
        reconnectDelay: @escaping @Sendable (Int) -> Duration = { attempt in
            .seconds(min(1 << min(attempt, 4), 15))
        }
    ) {
        storedSession = session
        self.workspace = workspace
        title = session?.title ?? "新对话"
        isRunning = session?.isRunning ?? false
        isLoading = session != nil
        agentName = profile.kind.title
        agentKind = profile.kind
        self.gateway = gateway ?? AgentGatewayFactory.make(profile: profile, password: password)
        self.reconnectDelay = reconnectDelay
        self.onSessionCreated = onSessionCreated
        self.onPromptAccepted = onPromptAccepted
    }

    func start() {
        guard eventTask == nil, startupTask == nil else { return }
        hasStarted = true
        modelCatalog = nil
        isModelLoading = true

        eventTask = Task { [weak self] in
            await self?.observeEvents()
        }

        startupTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await gateway.connect()
                isConnected = true
                isReconnecting = false
                if let storedSession {
                    let context = try await gateway.openSession(storedSession)
                    apply(context)
                    await loadModels()
                } else {
                    let context = try await gateway.createSession(in: workspace)
                    apply(context)
                    storedSession = context.session
                    onSessionCreated(context.session)
                    await loadModels()
                }
                errorMessage = nil
            } catch {
                isLoading = false
                isConnected = false
                isReconnecting = false
                isModelLoading = false
                errorMessage = error.localizedDescription
            }
            startupTask = nil
        }
    }

    func stop() {
        startupTask?.cancel()
        eventTask?.cancel()
        startupTask = nil
        eventTask = nil
        gateway.close()
        isConnected = false
        isReconnecting = false
        hasStarted = false
    }

    func reconnect() {
        stop()
        isLoading = true
        start()
    }

    func send() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }

        let requestID = UUID().uuidString
        composerText = ""
        errorMessage = nil
        messages.append(ConversationMessage(
            id: requestID,
            role: .user,
            text: text,
            reasoning: "",
            timestamp: Date(),
            sequence: nextSequence,
            isStreaming: false,
            isPending: true
        ))
        isRunning = true

        do {
            let activeRuntimeID: String
            if let runtimeSessionID {
                activeRuntimeID = runtimeSessionID
            } else {
                let context = try await gateway.createSession(in: workspace)
                apply(context, preservingMessages: true)
                await loadModels()
                activeRuntimeID = context.runtimeSessionID
                storedSession = context.session
                onSessionCreated(context.session)
            }

            try await sendPromptWithSessionRecovery(
                text: text,
                sessionID: activeRuntimeID,
                requestID: requestID
            )
            markUserCommitted(requestID: requestID, text: text)
            if let storedID = storedSession?.id {
                onPromptAccepted(storedID)
            }
        } catch {
            messages.removeAll { $0.id == requestID }
            composerText = text
            isRunning = false
            errorMessage = error.localizedDescription
        }
    }

    func sendGenUIAction(name: String, payload: [String: JSONValue]) async {
        guard !isRunning else {
            errorMessage = "请等待当前回复完成后再操作界面。"
            return
        }
        let componentData: String
        if let data = try? JSONEncoder().encode(JSONValue.object(payload)),
           let string = String(data: data, encoding: .utf8) {
            componentData = " 组件数据: \(string)"
        } else {
            componentData = ""
        }
        composerText = "[genui-action] \(name)。用户刚刚在界面中触发了动作 \"\(name)\"，请根据组件数据执行相应操作，并用 dsh-ui 输出更新后的界面。\(componentData)"
        await send()
    }

    func cancel() async {
        guard let runtimeSessionID, isRunning, !isStopping else { return }
        isStopping = true
        defer { isStopping = false }
        do {
            try await gateway.cancel(sessionID: runtimeSessionID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func respond(to approval: AgentApprovalRequest, choice: AgentApprovalChoice) async {
        guard pendingApprovals.contains(where: { $0.id == approval.id }),
              respondingApprovalID == nil else { return }
        respondingApprovalID = approval.id
        errorMessage = nil
        do {
            try await gateway.respond(to: approval, choice: choice)
            if !approval.waitsForResolutionEvent {
                pendingApprovals.removeAll { $0.id == approval.id }
                respondingApprovalID = nil
            }
        } catch {
            errorMessage = error.localizedDescription
            respondingApprovalID = nil
        }
    }

    func respond(to question: AgentQuestionRequest, answers: [AgentQuestionAnswer]) async {
        guard pendingQuestions.contains(where: { $0.id == question.id }),
              respondingQuestionID == nil else { return }
        respondingQuestionID = question.id
        errorMessage = nil
        do {
            try await gateway.respond(to: question, answers: answers)
            if !question.waitsForResolutionEvent {
                pendingQuestions.removeAll { $0.id == question.id }
                respondingQuestionID = nil
            }
        } catch {
            errorMessage = error.localizedDescription
            respondingQuestionID = nil
        }
    }

    func cancelQuestion(_ question: AgentQuestionRequest) async {
        guard pendingQuestions.contains(where: { $0.id == question.id }),
              respondingQuestionID == nil else { return }
        respondingQuestionID = question.id
        errorMessage = nil
        do {
            try await gateway.respondCancelled(to: question)
            if !question.waitsForResolutionEvent {
                pendingQuestions.removeAll { $0.id == question.id }
                respondingQuestionID = nil
            }
        } catch {
            errorMessage = error.localizedDescription
            respondingQuestionID = nil
        }
    }

    var canSelectModel: Bool {
        true
    }

    var currentModelDisplayName: String? {
        guard canSelectModel else { return nil }
        guard let catalog = modelCatalog, let selection = catalog.currentModel else { return nil }
        if let model = catalog.selectedModel {
            return model.displayName
        }
        return selection.modelID
    }

    var isCurrentModelAvailable: Bool {
        guard let catalog = modelCatalog, let selection = catalog.currentModel else { return true }
        return catalog.isAvailable(selection)
    }

    /// Reconciles the session's stored model selection with the fetched catalog.
    /// The stored selection (from session resume) can carry a provider that does
    /// not match the options list (often empty or a different slug), which makes
    /// the picker report the current model as unavailable even though it is listed.
    /// Fall back to matching by model id so the real model can be located.
    private func resolveCurrentModel(_ stored: AgentModelSelection?, fallback: AgentModelSelection?, in catalog: AgentModelCatalog) -> AgentModelSelection? {
        if let selection = stored, catalog.isAvailable(selection) { return selection }
        if let selection = stored,
           let model = catalog.allModels.first(where: { $0.id.lowercased() == selection.modelID.lowercased() }) {
            return AgentModelSelection(providerID: model.providerID, modelID: model.id, reasoningLevel: selection.reasoningLevel)
        }
        if let selection = fallback, catalog.isAvailable(selection) { return selection }
        return stored ?? fallback
    }

    func loadModels() async {
        guard canSelectModel else { return }
        // Drop overlapping requests: a foreground return can fire while the
        // initial load (or a previous refresh) is still in flight.
        guard !isFetchingModels else { return }
        guard let sessionID = runtimeSessionID ?? storedSession?.id else { return }

        // Keep the previously loaded list during background refreshes so the
        // picker never regresses to a spinner on every foreground return.
        let silent = modelCatalog != nil
        isFetchingModels = true
        if !silent { isModelLoading = true }
        defer {
            isFetchingModels = false
            if !silent { isModelLoading = false }
        }
        do {
            let catalog = try await gateway.fetchModels(sessionID: sessionID)
            let current = resolveCurrentModel(contextModel, fallback: catalog.currentModel, in: catalog)
            modelCatalog = AgentModelCatalog(
                groups: catalog.groups,
                currentModel: current,
                currentReasoningLevel: catalog.currentReasoningLevel,
                reasoningLevels: catalog.reasoningLevels,
                supportsReasoningLevel: catalog.supportsReasoningLevel
            )
        } catch {
            // Only surface errors on the blocking first load; keep the prior
            // catalog intact when a background refresh fails.
            if !silent { errorMessage = error.localizedDescription }
        }
    }

    func selectModel(_ model: AgentModel) async {
        guard canSelectModel, let sessionID = runtimeSessionID ?? storedSession?.id else { return }
        guard !isModelSelecting else { return }
        isModelSelecting = true
        errorMessage = nil
        let reasoningLevel: ReasoningLevel? = {
            guard model.supportsReasoningLevel else { return nil }
            let current = modelCatalog?.currentReasoningLevel ?? modelCatalog?.currentModel?.reasoningLevel
            if let current, model.reasoningLevels.contains(current) { return current }
            return model.defaultReasoningLevel ?? model.reasoningLevels.first
        }()
        let selection = AgentModelSelection(providerID: model.providerID, modelID: model.id, reasoningLevel: reasoningLevel)
        do {
            let confirmed = try await gateway.selectModel(selection, sessionID: sessionID)
            if let catalog = modelCatalog {
                modelCatalog = AgentModelCatalog(
                    groups: catalog.groups,
                    currentModel: confirmed ?? selection,
                    currentReasoningLevel: confirmed?.reasoningLevel ?? reasoningLevel,
                    reasoningLevels: catalog.reasoningLevels
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isModelSelecting = false
    }

    func selectReasoningLevel(_ level: ReasoningLevel) async {
        guard canSelectModel, let sessionID = runtimeSessionID ?? storedSession?.id else { return }
        guard let catalog = modelCatalog, let current = catalog.currentModel else { return }
        guard !isModelSelecting else { return }
        isModelSelecting = true
        errorMessage = nil
        let selection = AgentModelSelection(
            providerID: current.providerID,
            modelID: current.modelID,
            reasoningLevel: level
        )
        do {
            let confirmed = try await gateway.selectModel(selection, sessionID: sessionID)
            modelCatalog = AgentModelCatalog(
                groups: catalog.groups,
                currentModel: AgentModelSelection(
                    providerID: current.providerID,
                    modelID: current.modelID,
                    reasoningLevel: confirmed?.reasoningLevel ?? level
                ),
                currentReasoningLevel: confirmed?.reasoningLevel ?? level,
                reasoningLevels: catalog.reasoningLevels
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isModelSelecting = false
    }

    private func apply(_ context: AgentConversationContext, preservingMessages: Bool = false) {
        runtimeSessionID = context.runtimeSessionID
        storedSession = context.session
        title = context.title
        isRunning = context.isRunning
        isLoading = false
        contextModel = context.currentModel
        if !preservingMessages {
            messages = context.messages
        }
    }

    func handle(_ event: AgentGatewayEvent) {
        switch event {
        case .connected:
            isConnected = true
            isReconnecting = false
            if errorMessage?.hasPrefix("实时连接") == true {
                errorMessage = nil
            }

        case .userCommitted(let sessionID, let requestID, let text):
            guard isCurrent(sessionID) else { return }
            markUserCommitted(requestID: requestID, text: text)

        case .assistantDelta(let sessionID, let messageKey, let text, let reasoning):
            guard isCurrent(sessionID), !text.isEmpty else { return }
            let index = assistantIndex(for: messageKey)
                ?? (messageKey == nil ? activeAssistantIndex : nil)
                ?? appendAssistant(messageKey: messageKey)
            if reasoning {
                messages[index].reasoning += text
            } else {
                messages[index].text += text
            }
            messages[index].isStreaming = true
            isRunning = true

        case .assistantComplete(let sessionID, let messageKey, let text, let reasoning):
            guard isCurrent(sessionID) else { return }
            let matchingIndex = assistantIndex(for: messageKey)
                ?? (messageKey == nil ? activeAssistantIndex : nil)
                ?? matchingAssistantIndex(text: text, reasoning: reasoning)
            if let index = matchingIndex {
                if !text.isEmpty { messages[index].text = text }
                if !reasoning.isEmpty { messages[index].reasoning = reasoning }
                messages[index].isStreaming = false
            } else if !text.isEmpty || !reasoning.isEmpty {
                let index = appendAssistant(messageKey: messageKey)
                messages[index].text = text
                messages[index].reasoning = reasoning
                messages[index].isStreaming = false
            }

        case .toolStarted(let sessionID, let id, let name, let detail):
            guard isCurrent(sessionID) else { return }
            finishStreamingAssistant()
            if let detail, !detail.isEmpty {
                toolDetails[id] = detail
                if let approvalIndex = pendingApprovals.firstIndex(where: { $0.callID == id && $0.command == nil }) {
                    pendingApprovals[approvalIndex].command = detail
                }
            }
            messages.append(ConversationMessage(
                id: "tool-\(id)",
                role: .activity,
                text: "正在使用 \(name)",
                reasoning: "",
                timestamp: Date(),
                sequence: nextSequence,
                isStreaming: true,
                isPending: false
            ))
            isRunning = true

        case .toolCompleted(let sessionID, let id, let name):
            guard isCurrent(sessionID) else { return }
            let index = messages.firstIndex(where: { $0.id == "tool-\(id)" })
                ?? messages.lastIndex(where: { $0.role == .activity && $0.isStreaming })
            guard let index else { return }
            let toolName = name ?? messages[index].text.replacingOccurrences(of: "正在使用 ", with: "")
            messages[index].text = "已使用 \(toolName)"
            messages[index].isStreaming = false

        case .title(let sessionID, let value):
            guard isCurrent(sessionID), !value.isEmpty else { return }
            title = value

        case .running(let sessionID, let value):
            guard isCurrent(sessionID) else { return }
            isRunning = value
            if !value { finishStreamingAssistant() }

        case .approvalRequested(var approval):
            guard isCurrent(approval.sessionID) else { return }
            finishStreamingAssistant()
            if approval.command == nil, let callID = approval.callID {
                approval.command = toolDetails[callID]
            }
            if let index = pendingApprovals.firstIndex(where: { $0.id == approval.id }) {
                pendingApprovals[index] = approval
            } else {
                pendingApprovals.append(approval)
            }
            isRunning = true

        case .approvalResolved(let sessionID, let approvalID, _):
            guard isCurrent(sessionID) else { return }
            pendingApprovals.removeAll { $0.id == approvalID }
            if respondingApprovalID == approvalID { respondingApprovalID = nil }

        case .questionRequested(var question):
            guard isCurrent(question.sessionID) else { return }
            finishStreamingAssistant()
            if let index = pendingQuestions.firstIndex(where: { $0.id == question.id }) {
                pendingQuestions[index] = question
            } else {
                pendingQuestions.append(question)
            }
            isRunning = true

        case .questionResolved(let sessionID, let questionRpcId, _):
            guard isCurrent(sessionID) else { return }
            pendingQuestions.removeAll { $0.responseToken == questionRpcId }
            if respondingQuestionID == questionRpcId { respondingQuestionID = nil }

        case .failure(let message):
            errorMessage = message
        }
    }

    private func isCurrent(_ sessionID: String) -> Bool {
        sessionID == runtimeSessionID || sessionID == storedSession?.id
    }

    private func markUserCommitted(requestID: String?, text: String?) {
        let index: Int?
        if let requestID {
            index = messages.firstIndex { $0.id == requestID }
        } else if let text {
            index = messages.lastIndex { $0.role == .user && $0.text == text && $0.isPending }
        } else {
            index = messages.lastIndex { $0.role == .user && $0.isPending }
        }
        if let index { messages[index].isPending = false }
    }

    private var activeAssistantIndex: Int? {
        messages.lastIndex { $0.role == .assistant && $0.isStreaming }
    }

    @discardableResult
    private func assistantIndex(for messageKey: String?) -> Int? {
        guard let messageKey else { return nil }
        return messages.firstIndex { $0.id == "assistant-\(messageKey)" }
    }

    private func matchingAssistantIndex(text: String, reasoning: String) -> Int? {
        guard let index = messages.lastIndex(where: { $0.role == .assistant }),
              messages[index].text == text,
              messages[index].reasoning == reasoning else { return nil }
        let lastUserIndex = messages.lastIndex { $0.role == .user }
        guard lastUserIndex == nil || index > lastUserIndex! else { return nil }
        return index
    }

    @discardableResult
    private func appendAssistant(messageKey: String? = nil) -> Int {
        messages.append(ConversationMessage(
            id: messageKey.map { "assistant-\($0)" } ?? "assistant-\(UUID().uuidString)",
            role: .assistant,
            text: "",
            reasoning: "",
            timestamp: Date(),
            sequence: nextSequence,
            isStreaming: true,
            isPending: false
        ))
        return messages.index(before: messages.endIndex)
    }

    private func finishStreamingAssistant() {
        if let index = activeAssistantIndex { messages[index].isStreaming = false }
    }

    private func sendPromptWithSessionRecovery(
        text: String,
        sessionID: String,
        requestID: String
    ) async throws {
        do {
            try await gateway.send(text: text, sessionID: sessionID, requestID: requestID)
        } catch {
            guard isMissingRemoteSession(error), let storedSession else { throw error }

            // Hermes runtime sessions can expire while the stored session remains valid.
            // Resume it once and retry the same prompt with the fresh runtime ID.
            let context = try await gateway.openSession(storedSession)
            apply(context, preservingMessages: true)
            isRunning = true
            try await gateway.send(
                text: text,
                sessionID: context.runtimeSessionID,
                requestID: requestID
            )
        }
    }

    private func isMissingRemoteSession(_ error: Error) -> Bool {
        let description = "\(error) \(error.localizedDescription)".lowercased()
        return description.contains("session not found")
            || description.contains("session_not_found")
            || (description.contains("session") && description.contains("does not exist"))
    }

    private var nextSequence: Int {
        (messages.map(\.sequence).max() ?? -1) + 1
    }

    private func observeEvents() async {
        var failedAttempts = 0
        while !Task.isCancelled {
            do {
                let events = gateway.events()
                try await gateway.connect()
                for try await event in events {
                    guard !Task.isCancelled else { return }
                    if case .connected = event { failedAttempts = 0 }
                    handle(event)
                }
            } catch {
                guard !Task.isCancelled else { return }
                markConnectionLost(error, failedAttempts: failedAttempts)
            }

            guard !Task.isCancelled else { return }
            let delay = reconnectDelay(failedAttempts)
            failedAttempts += 1
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
        }
    }

    private func markConnectionLost(_ error: Error, failedAttempts: Int) {
        guard eventTask != nil else { return }
        isConnected = false
        isReconnecting = true
        if failedAttempts >= 2 {
            errorMessage = "实时连接不稳定，正在自动重连：\(error.localizedDescription)"
        }
    }
}
