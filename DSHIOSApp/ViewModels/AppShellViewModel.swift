import Foundation

struct ConversationTarget: Identifiable, Equatable, Sendable {
    let id: UUID
    var session: AgentSessionSummary?
    var workspaceID: String?

    init(session: AgentSessionSummary? = nil, workspaceID: String? = nil) {
        id = UUID()
        self.session = session
        self.workspaceID = workspaceID
    }
}

@MainActor
final class AppShellViewModel: ObservableObject {
    @Published private(set) var sessions: [AgentSessionSummary] = []
    @Published private(set) var workspaces: [AgentWorkspace] = []
    @Published private(set) var archivedSessionIDs: Set<String> = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var target = ConversationTarget()

    private var gateway: (any AgentGateway)?
    private var serverKind: AgentServerKind?

    func configure(profile: ServerProfile, password: String) async {
        gateway?.close()
        gateway = AgentGatewayFactory.make(profile: profile, password: password)
        serverKind = profile.kind
        sessions = []
        workspaces = []
        archivedSessionIDs = []
        errorMessage = nil
        target = ConversationTarget()
        await load()
    }

    func load() async {
        guard let gateway, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let snapshot = try await gateway.navigation()
            sessions = snapshot.sessions.sorted(by: AgentSessionOrdering.newestFirst)
            workspaces = snapshot.workspaces
            archivedSessionIDs = snapshot.archivedSessionIDs
            errorMessage = nil

            if let currentID = target.session?.id,
               let refreshed = sessions.first(where: { $0.id == currentID }) {
                target.session = refreshed
            } else if target.session == nil,
                      target.workspaceID == nil,
                      let defaultWorkspaceID {
                target = ConversationTarget(workspaceID: defaultWorkspaceID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectSession(_ session: AgentSessionSummary, workspaceID: String?) {
        target = ConversationTarget(session: session, workspaceID: workspaceID)
    }

    func startNewConversation(workspaceID: String? = nil) {
        let workspaceID = workspaceID ?? defaultWorkspaceID
        let reusableBlank: AgentSessionSummary?
        if let workspaceID,
           let workspace = workspaces.first(where: { $0.id == workspaceID }) {
            reusableBlank = workspace.sessionIDs
                .compactMap { id in sessions.first(where: { $0.id == id }) }
                .first { $0.isBlank && $0.workingDirectory == workspace.path }
        } else {
            reusableBlank = nil
        }
        target = ConversationTarget(session: reusableBlank, workspaceID: workspaceID)
    }

    private var defaultWorkspaceID: String? {
        guard serverKind == .dsh else { return nil }
        return AgentWorkspaceSelection.defaultDSHWorkspaceID(in: workspaces)
    }

    func attachCreatedSession(_ session: AgentSessionSummary, to targetID: UUID) {
        guard target.id == targetID else { return }
        target.session = session
        if !sessions.contains(where: { $0.id == session.id }) {
            sessions.insert(session, at: 0)
        }
    }

    func markSessionStarted(_ sessionID: String, targetID: UUID) {
        if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[index].isBlank = false
            sessions[index].updatedAt = Date()
        }
        if target.id == targetID {
            target.session?.isBlank = false
            target.session?.updatedAt = Date()
        }
    }

    func sessions(in workspace: AgentWorkspace) -> [AgentSessionSummary] {
        workspace.sessionIDs.compactMap { id in
            sessions.first { $0.id == id && !$0.isBlank && !archivedSessionIDs.contains($0.id) }
        }
        .sorted(by: AgentSessionOrdering.newestFirst)
    }

    var ungroupedSessions: [AgentSessionSummary] {
        let groupedIDs = Set(workspaces.flatMap(\.sessionIDs))
        return sessions.filter {
            !$0.isBlank && !archivedSessionIDs.contains($0.id) && !groupedIDs.contains($0.id)
        }
        .sorted(by: AgentSessionOrdering.newestFirst)
    }
}
