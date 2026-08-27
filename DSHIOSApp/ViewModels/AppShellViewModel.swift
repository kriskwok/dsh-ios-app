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
    @Published private(set) var pendingResponseIDs: Set<String> = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var operationError: String?
    @Published private(set) var target = ConversationTarget()

    private var gateway: (any AgentGateway)?
    private var serverKind: AgentServerKind?
    private var currentProfileID: UUID?

    func configure(profile: ServerProfile, password: String) async {
        gateway?.close()
        gateway = AgentGatewayFactory.make(profile: profile, password: password)
        serverKind = profile.kind
        currentProfileID = profile.id
        errorMessage = nil

        if let cached = Self.loadCache(profileID: profile.id) {
            sessions = cached.sessions.sorted(by: AgentSessionOrdering.newestFirst)
            workspaces = cached.workspaces
            archivedSessionIDs = cached.archivedSessionIDs
        } else {
            sessions = []
            workspaces = []
            archivedSessionIDs = []
        }
        target = ConversationTarget()
        pendingResponseIDs = []
        await load()
    }

    func load() async {
        guard let gateway, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let hasCachedData = !sessions.isEmpty

        do {
            let snapshot = try await gateway.navigation()
            let previouslyRunningIDs = Set(sessions.filter(\.isRunning).map(\.id))
            sessions = snapshot.sessions.sorted(by: AgentSessionOrdering.newestFirst)
            workspaces = snapshot.workspaces
            archivedSessionIDs = snapshot.archivedSessionIDs
            errorMessage = nil

            if let pid = currentProfileID {
                Self.saveCache(profileID: pid, snapshot: snapshot)
            }

            if let currentID = target.session?.id,
               let refreshed = sessions.first(where: { $0.id == currentID }) {
                target.session = refreshed
            } else if target.session == nil,
                      target.workspaceID == nil,
                      let defaultWorkspaceID {
                target = ConversationTarget(workspaceID: defaultWorkspaceID)
            }

            let currentlyRunningIDs = Set(snapshot.sessions.filter(\.isRunning).map(\.id))
            let selectedID = target.session?.id
            pendingResponseIDs = previouslyRunningIDs
                .subtracting(currentlyRunningIDs)
                .subtracting([selectedID].compactMap { $0 })
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            if !hasCachedData {
                errorMessage = error.localizedDescription
            }
        }
    }

    func selectSession(_ session: AgentSessionSummary, workspaceID: String?) {
        pendingResponseIDs.remove(session.id)
        target = ConversationTarget(session: session, workspaceID: workspaceID)
    }

    func startNewConversation(workspace: AgentWorkspace? = nil) {
        let resolvedWorkspace = workspace ?? defaultWorkspace
        let reusableBlank: AgentSessionSummary?
        if let resolvedWorkspace {
            reusableBlank = resolvedWorkspace.sessionIDs
                .compactMap { id in sessions.first(where: { $0.id == id }) }
                .first { $0.isBlank && $0.workingDirectory == resolvedWorkspace.path }
        } else {
            reusableBlank = nil
        }

        target = ConversationTarget(session: reusableBlank, workspaceID: resolvedWorkspace?.id)
    }

    private var defaultWorkspace: AgentWorkspace? {
        defaultWorkspaceID.flatMap { id in
            workspaces.first(where: { $0.id == id })
        }
    }

    private var defaultWorkspaceID: String? {
        switch serverKind {
        case .dsh:
            return AgentWorkspaceSelection.defaultDSHWorkspaceID(in: workspaces)
        case .codex:
            return workspaces.first { $0.path == CodexAgentGateway.defaultWorkspacePath }?.id
        case .hermes:
            return nil
        case nil:
            return nil
        }
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

    func updateSessionRunning(_ sessionID: String, isRunning: Bool) {
        if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[index].isRunning = isRunning
        }
        if target.session?.id == sessionID {
            target.session?.isRunning = isRunning
        }
    }

    func renameSession(_ session: AgentSessionSummary, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != session.title else { return }
        do {
            try await gateway?.renameSession(session.id, title: trimmed)
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[index].title = trimmed
            }
            if target.session?.id == session.id {
                target.session?.title = trimmed
            }
            persistCache()
            operationError = nil
        } catch {
            operationError = "重命名失败：\(error.localizedDescription)"
        }
    }

    func archiveSession(_ session: AgentSessionSummary, archived: Bool) async {
        do {
            try await gateway?.archiveSession(session.id, archived: archived)
            if archived {
                archivedSessionIDs.insert(session.id)
            } else {
                archivedSessionIDs.remove(session.id)
            }
            if target.session?.id == session.id, archived {
                target = ConversationTarget()
            }
            persistCache()
            operationError = nil
        } catch {
            operationError = "归档失败：\(error.localizedDescription)"
        }
    }

    private func persistCache() {
        guard let pid = currentProfileID else { return }
        let snapshot = AgentNavigationSnapshot(
            sessions: sessions,
            workspaces: workspaces,
            archivedSessionIDs: archivedSessionIDs
        )
        Self.saveCache(profileID: pid, snapshot: snapshot)
    }

    func sessions(in workspace: AgentWorkspace) -> [AgentSessionSummary] {
        workspace.sessionIDs.compactMap { id in
            sessions.first { $0.id == id && (serverKind == .codex || !$0.isBlank) && !archivedSessionIDs.contains($0.id) }
        }
        .sorted(by: AgentSessionOrdering.newestFirst)
    }

    var ungroupedSessions: [AgentSessionSummary] {
        let groupedIDs = Set(workspaces.flatMap(\.sessionIDs))
        return sessions.filter {
           (serverKind == .codex || !$0.isBlank) && !archivedSessionIDs.contains($0.id) && !groupedIDs.contains($0.id)
        }
        .sorted(by: AgentSessionOrdering.newestFirst)
    }

    private static func cacheFileURL(profileID: UUID) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("session_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(profileID.uuidString).json")
    }

    private static func loadCache(profileID: UUID) -> AgentNavigationSnapshot? {
        let url = cacheFileURL(profileID: profileID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AgentNavigationSnapshot.self, from: data)
    }

    private static func saveCache(profileID: UUID, snapshot: AgentNavigationSnapshot) {
        let url = cacheFileURL(profileID: profileID)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
