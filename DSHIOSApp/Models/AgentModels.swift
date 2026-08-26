import Foundation

enum AgentServerKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case dsh
    case hermes
    case codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dsh: return "DSH"
        case .hermes: return "Hermes"
        case .codex: return "Codex"
        }
    }
}

struct AgentSessionSummary: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var title: String
    var updatedAt: Date
    var isRunning: Bool
    var isBlank: Bool
    var workingDirectory: String?
    var source: String?
    var modelProvider: String?

    init(
        id: String,
        title: String = "新对话",
        updatedAt: Date = Date(),
        isRunning: Bool = false,
        isBlank: Bool = false,
        workingDirectory: String? = nil,
        source: String? = nil,
        modelProvider: String? = nil
    ) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.isRunning = isRunning
        self.isBlank = isBlank
        self.workingDirectory = workingDirectory
        self.source = source
        self.modelProvider = modelProvider
    }

    var channel: AgentSessionChannel { AgentSessionChannel(source: source) }
}

enum AgentSessionOrdering {
    static func newestFirst(_ lhs: AgentSessionSummary, _ rhs: AgentSessionSummary) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
    }

    static func latestUpdate(in sessions: [AgentSessionSummary]) -> Date? {
        sessions.map(\.updatedAt).max()
    }
}

enum SessionTimestampFormatter {
    static func string(
        for date: Date,
        relativeTo now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            let components = calendar.dateComponents([.hour, .minute], from: date)
            return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
        }

        let dateYear = calendar.component(.year, from: date)
        if dateYear == calendar.component(.year, from: now) {
            return "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
        }
        return "\(dateYear)年"
    }
}

struct AgentSessionChannel: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let systemImage: String
    let sortOrder: Int

    init(source: String?) {
        let normalized = source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch normalized {
        case "ios", "iphone", "dsh-ios", "dsh-ios-app", "mobile":
            self.init(id: "ios", title: "APP", systemImage: "iphone", sortOrder: 0)
        case "weixin", "wechat":
            self.init(id: "weixin", title: "微信", systemImage: "message.fill", sortOrder: 10)
        case "feishu", "lark":
            self.init(id: "feishu", title: "飞书", systemImage: "paperplane.fill", sortOrder: 20)
        case "cli":
            self.init(id: "cli", title: "CLI", systemImage: "terminal", sortOrder: 30)
        case "tui":
            self.init(id: "tui", title: "TUI", systemImage: "rectangle.and.text.magnifyingglass", sortOrder: 40)
        case "desktop", "webui":
            self.init(id: "desktop", title: "桌面端", systemImage: "desktopcomputer", sortOrder: 50)
        case "subagent", "cron", "webhook", "api_server", "msgraph_webhook", "kanban", "tool":
            self.init(id: "automation", title: "自动任务", systemImage: "gearshape.2", sortOrder: 900)
        case "":
            self.init(id: "other", title: "其他", systemImage: "tray", sortOrder: 1_000)
        default:
            self.init(
                id: "source:\(normalized)",
                title: normalized.replacingOccurrences(of: "_", with: " ").capitalized,
                systemImage: "network",
                sortOrder: 100
            )
        }
    }

    private init(id: String, title: String, systemImage: String, sortOrder: Int) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.sortOrder = sortOrder
    }
}

struct AgentWorkspace: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let path: String
    let title: String
    let sessionIDs: [String]
}

enum AgentWorkspaceSelection {
    static func defaultDSHWorkspaceID(in workspaces: [AgentWorkspace]) -> String? {
        workspaces.first { workspace in
            normalized(workspace.title) == "dshworkspace"
                || normalized(URL(fileURLWithPath: workspace.path).lastPathComponent) == "dshworkspace"
        }?.id
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }
}

struct AgentNavigationSnapshot: Codable, Sendable {
    let sessions: [AgentSessionSummary]
    let workspaces: [AgentWorkspace]
    let archivedSessionIDs: Set<String>
}

struct AgentConversationContext: Sendable {
    let runtimeSessionID: String
    let session: AgentSessionSummary
    let messages: [ConversationMessage]
    let title: String
    let isRunning: Bool
    var currentModel: AgentModelSelection?
    var metrics: AgentSessionMetrics?
}

struct AgentSessionMetrics: Equatable, Sendable {
    let contextUsageRatio: Double?
    let cacheHitRatio: Double?

    init(contextUsageRatio: Double? = nil, cacheHitRatio: Double? = nil) {
        self.contextUsageRatio = Self.normalizedRatio(contextUsageRatio)
        self.cacheHitRatio = Self.normalizedRatio(cacheHitRatio)
    }

    init?(json value: JSONValue?) {
        guard let value else { return nil }
        // DSH format: contextPressure and tokenUsage at top level
        let dshContext = Self.contextFromDSHPressure(in: value)
        let dshCache = Self.cacheFromDSHTokenUsage(in: value)
        // Hermes/Codex format: context_percent / cache at various levels
        let hermesContext = Self.contextPercentFromUsage(in: value)
        let hermesCache = Self.cacheHitFromUsage(in: value)
        let ctx = dshContext ?? hermesContext
        let cache = dshCache ?? hermesCache
        guard ctx != nil || cache != nil else { return nil }
        self.init(contextUsageRatio: ctx, cacheHitRatio: cache)
    }

    private static func contextFromDSHPressure(in value: JSONValue) -> Double? {
        guard let pressure = value["contextPressure"] else { return nil }
        let projected = pressure["projectedTokens"]?.doubleValue
        let window = pressure["contextWindow"]?.doubleValue
        if let projected, let window, window > 0 { return projected / window }
        return nil
    }

    private static func cacheFromDSHTokenUsage(in value: JSONValue) -> Double? {
        guard let usage = value["tokenUsage"] else { return nil }
        let cached = usage["cacheReadTokens"]?.doubleValue
        let uncached = usage["uncachedInputTokens"]?.doubleValue
        if let cached, let uncached {
            let total = cached + uncached
            if total > 0 { return cached / total }
        }
        return nil
    }

    func merging(_ newer: AgentSessionMetrics?) -> AgentSessionMetrics {
        guard let newer else { return self }
        return AgentSessionMetrics(
            contextUsageRatio: newer.contextUsageRatio ?? contextUsageRatio,
            cacheHitRatio: newer.cacheHitRatio ?? cacheHitRatio
        )
    }

    private static func contextPercentFromUsage(in value: JSONValue) -> Double? {
        // Try direct keys at multiple levels
        if let ratio = Self.directRatio(value, keys: ["context_percent", "contextPercent", "contextUsage", "context_usage"]) {
            return ratio
        }
        // Try inside nested containers
        let containers = [value["usage"], value["tokenUsage"], value["token_usage"], value["tokens"]]
        for container in containers {
            if let container, let ratio = Self.directRatio(container, keys: ["context_percent", "contextPercent", "contextUsage", "context_usage"]) {
                return ratio
            }
        }
        // Try computing from token counts
        if let ratio = Self.contextRatioFromTokens(in: value) {
            return ratio
        }
        return nil
    }

    private static func cacheHitFromUsage(in value: JSONValue) -> Double? {
        // Try direct keys at multiple levels
        if let ratio = Self.directRatio(value, keys: ["cacheHitRate", "cache_hit_rate", "cacheHit", "cache_hit", "cachedTokensRatio"]) {
            return ratio
        }
        // Try inside nested containers
        let containers = [value["usage"], value["tokenUsage"], value["token_usage"], value["tokens"]]
        for container in containers {
            if let container {
                if let ratio = Self.directRatio(container, keys: ["cacheHitRate", "cache_hit_rate", "cacheHit", "cache_hit", "cachedTokensRatio"]) {
                    return ratio
                }
                // Try computing from token counts
                let cached = Self.firstNumber(container, keys: ["cached_tokens", "cachedTokens", "cache_read_tokens", "cacheReadTokens"], allowingZero: true)
                let total = Self.firstNumber(container, keys: ["prompt_tokens", "promptTokens", "input_tokens", "inputTokens"], allowingZero: true)
                if let cached, let total, total > 0 {
                    return cached / total
                }
            }
        }
        return nil
    }

    private static func contextRatioFromTokens(in value: JSONValue) -> Double? {
        let containers = [value["usage"], value["tokenUsage"], value["token_usage"], value["tokens"]]
        for container in containers {
            guard let container else { continue }
            let numerator = firstNumber(container, keys: ["context_used", "contextUsed", "context_tokens", "contextTokens"], allowingZero: true)
            let denominator = firstNumber(container, keys: ["context_max", "contextMax", "context_window", "contextWindow", "max_context_tokens", "maxContextTokens"], allowingZero: true)
            if let numerator, let denominator, denominator > 0 {
                return numerator / denominator
            }
        }
        return nil
    }

    private static func directRatio(_ value: JSONValue, keys: [String]) -> Double? {
        for key in keys {
            if let ratio = value[key]?.doubleValue {
                return ratio
            }
        }
        return nil
    }

    private static func firstNumber(_ value: JSONValue, keys: [String], allowingZero: Bool) -> Double? {
        for key in keys {
            guard let number = value[key]?.doubleValue else { continue }
            if allowingZero ? number >= 0 : number > 0 { return number }
        }
        return nil
    }

    private static func normalizedRatio(_ value: Double?) -> Double? {
        guard var value, value.isFinite, value >= 0 else { return nil }
        if value > 1, value <= 100 { value /= 100 }
        return value > 1 ? nil : value
    }
}

enum AgentApprovalChoice: String, CaseIterable, Hashable, Sendable {
    case once
    case session
    case always
    case deny

    var title: String {
        switch self {
        case .once: return "允许一次"
        case .session: return "本会话允许"
        case .always: return "始终允许"
        case .deny: return "拒绝"
        }
    }
}

struct AgentApprovalRequest: Identifiable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let responseToken: String?
    let toolName: String
    let description: String
    var command: String?
    let callID: String?
    let choices: [AgentApprovalChoice]
    let isSmartDenied: Bool
    let waitsForResolutionEvent: Bool
}

struct AgentQuestionOption: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let description: String?
}

struct AgentQuestion: Identifiable, Equatable, Sendable {
    let id: String
    let question: String
    let detail: String?
    let header: String?
    let options: [AgentQuestionOption]
    let multiSelect: Bool
}

struct AgentQuestionRequest: Identifiable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let responseToken: String?
    let questions: [AgentQuestion]
    let waitsForResolutionEvent: Bool
}

struct AgentQuestionAnswer: Equatable, Sendable {
    let id: String
    let selected: [String]
    let custom: String?
}

enum AgentGatewayEvent: Sendable {
    case connected
    case userCommitted(sessionID: String, requestID: String?, text: String?)
    case assistantDelta(sessionID: String, messageKey: String?, text: String, reasoning: Bool)
    case assistantComplete(sessionID: String, messageKey: String?, text: String, reasoning: String)
    case toolStarted(sessionID: String, id: String, name: String, detail: String?)
    case toolCompleted(sessionID: String, id: String, name: String?)
    case title(sessionID: String, value: String)
    case running(sessionID: String, value: Bool)
    case approvalRequested(AgentApprovalRequest)
    case approvalResolved(sessionID: String, approvalID: String, outcome: String)
    case questionRequested(AgentQuestionRequest)
    case questionResolved(sessionID: String, questionRpcId: String, outcome: String)
    case sessionMetrics(sessionID: String, metrics: AgentSessionMetrics)
    case failure(String)
}

protocol AgentGateway: AnyObject, Sendable {
    func connect() async throws
    func navigation() async throws -> AgentNavigationSnapshot
    func openSession(_ session: AgentSessionSummary) async throws -> AgentConversationContext
    func createSession(in workspace: AgentWorkspace?) async throws -> AgentConversationContext
    func send(text: String, sessionID: String, requestID: String) async throws
    func cancel(sessionID: String) async throws
    func respond(to approval: AgentApprovalRequest, choice: AgentApprovalChoice) async throws
    func respond(to question: AgentQuestionRequest, answers: [AgentQuestionAnswer]) async throws
    func respondCancelled(to question: AgentQuestionRequest) async throws
    func events() -> AsyncThrowingStream<AgentGatewayEvent, Error>
    func close()
    func fetchModels(sessionID: String) async throws -> AgentModelCatalog
    func selectModel(_ selection: AgentModelSelection, sessionID: String) async throws -> AgentModelSelection?
}

extension AgentGateway {
    func respond(to question: AgentQuestionRequest, answers: [AgentQuestionAnswer]) async throws {
        throw AgentGatewayUnsupportedError()
    }

    func respondCancelled(to question: AgentQuestionRequest) async throws {
        throw AgentGatewayUnsupportedError()
    }
}

struct AgentGatewayUnsupportedError: LocalizedError {
    var errorDescription: String? { "当前服务器不支持提问功能" }
}
