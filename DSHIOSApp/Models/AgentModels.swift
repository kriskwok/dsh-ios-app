import Foundation

enum AgentServerKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case dsh
    case hermes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dsh: return "DSH"
        case .hermes: return "Hermes"
        }
    }

}

struct AgentSessionSummary: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var updatedAt: Date
    var isRunning: Bool
    var isBlank: Bool
    var workingDirectory: String?
    var source: String?

    init(
        id: String,
        title: String = "新对话",
        updatedAt: Date = Date(),
        isRunning: Bool = false,
        isBlank: Bool = false,
        workingDirectory: String? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.isRunning = isRunning
        self.isBlank = isBlank
        self.workingDirectory = workingDirectory
        self.source = source
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
            self.init(id: "ios", title: "iPhone", systemImage: "iphone", sortOrder: 0)
        case "desktop", "webui":
            self.init(id: "desktop", title: "Desktop", systemImage: "desktopcomputer", sortOrder: 10)
        case "cli":
            self.init(id: "cli", title: "CLI", systemImage: "terminal", sortOrder: 20)
        case "tui":
            self.init(id: "tui", title: "TUI", systemImage: "rectangle.and.text.magnifyingglass", sortOrder: 30)
        case "weixin", "wechat":
            self.init(id: "weixin", title: "微信", systemImage: "message.fill", sortOrder: 40)
        case "feishu", "lark":
            self.init(id: "feishu", title: "飞书", systemImage: "paperplane.fill", sortOrder: 50)
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

struct AgentWorkspace: Identifiable, Hashable, Sendable {
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

struct AgentNavigationSnapshot: Sendable {
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
    func events() -> AsyncThrowingStream<AgentGatewayEvent, Error>
    func close()
}
