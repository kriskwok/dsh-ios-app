import SwiftUI

struct ConversationDrawerView: View {
    let profile: ServerProfile?
    let profiles: [ServerProfile]
    let workspaces: [AgentWorkspace]
    let sessionsForWorkspace: (AgentWorkspace) -> [AgentSessionSummary]
    let ungroupedSessions: [AgentSessionSummary]
    let selectedSessionID: String?
    let pendingResponseIDs: Set<String>
    let isLoading: Bool
    let errorMessage: String?
    let isConnected: Bool
    let isReconnecting: Bool
    let isDrawerGestureActive: Bool
    let onNewConversation: (AgentWorkspace?) -> Void
    let onSelectSession: (AgentSessionSummary, String?) -> Void
    let onRefresh: () async -> Void
    let onOpenSettings: () -> Void
    let onSelectServer: (ServerProfile) -> Void

    @State private var collapsedWorkspaceIDs: Set<String> = []
    @State private var collapsedChannelIDs: Set<String> = ["automation"]
    @State private var showsServerSwitcher = false

    private let horizontalPadding: CGFloat = 22
    private let logoSize: CGFloat = 42
    private let logoSpacing: CGFloat = 10

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: logoSpacing) {
                if let profile {
                    AgentLogoView(kind: profile.kind, size: logoSize)
                } else {
                    Image(systemName: "server.rack")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: logoSize, height: logoSize)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(profile?.name ?? "Agent")
                            .font(.title3.weight(.bold))
                            .lineLimit(1)
                        if !otherProfiles.isEmpty {
                            serverSwitcherButton
                        }
                    }
                    Text(profile?.displayAddress ?? "未选择服务器")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 7, height: 7)
                    Text(connectionTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(connectionColor)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 14)
            .padding(.bottom, 14)

            Divider()

            ZStack(alignment: .bottomLeading) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if isLoading && workspaces.isEmpty && ungroupedSessions.isEmpty {
                            HStack(spacing: 9) {
                                ProgressView().controlSize(.small)
                                Text("正在读取会话…")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(18)
                        }

                        if profile?.kind == .hermes {
                            ForEach(channelSections) { channel in
                                channelSection(channel)
                            }
                        } else {
                            ForEach(orderedWorkspaces()) { workspace in
                                dshWorkspaceSection(workspace)
                            }
                        }

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(16)
                        }
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 104)
                    .padding(.horizontal, 6)
                }
                .scrollDisabled(isDrawerGestureActive)
                .refreshable { await onRefresh() }

                HStack(spacing: 12) {
                    Button { onNewConversation(nil) } label: {
                        Label("聊天", systemImage: "square.and.pencil")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .frame(height: 56)
                            .background(Color.accentColor, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(profile == nil)
                    .accessibilityLabel("聊天")

                    Spacer(minLength: 12)

                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 22, weight: .semibold))
                            .frame(width: 56, height: 56)
                            .background(.regularMaterial, in: Circle())
                            .overlay(Circle().stroke(Color.primary.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("服务器设置")
                }
                .padding(.leading, horizontalPadding)
                .padding(.trailing, horizontalPadding)
                .padding(.bottom, 12)
                .safeAreaPadding(.bottom, 8)
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .ignoresSafeArea(edges: .bottom)
    }

    private var connectionTitle: String {
        guard profile != nil else { return "未连接" }
        if isConnected { return "已连接" }
        if isReconnecting { return "重连中" }
        return "连接中"
    }

    private var connectionColor: Color {
        if isConnected { return .green }
        if isReconnecting { return .orange }
        return .secondary
    }

    private var otherProfiles: [ServerProfile] {
        guard let profile else { return [] }
        return profiles.filter { $0.id != profile.id }
    }

    private var serverSwitcherButton: some View {
        Button {
            showsServerSwitcher = true
        } label: {
            Image(systemName: "switch.2")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.07), in: Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("切换服务器")
        .popover(isPresented: $showsServerSwitcher, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(otherProfiles) { candidate in
                    Button {
                        showsServerSwitcher = false
                        onSelectServer(candidate)
                    } label: {
                        HStack(spacing: 12) {
                            AgentLogoView(kind: candidate.kind, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(candidate.kind.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if candidate.id != otherProfiles.last?.id {
                        Divider()
                    }
                }
            }
            .frame(minWidth: 230)
            .padding(6)
            .presentationCompactAdaptation(.popover)
        }
    }

    private var channelSections: [AgentSessionChannel] {
        let grouped = Dictionary(grouping: visibleSessions, by: \.channel)
        return grouped.keys.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            let lhsDate = AgentSessionOrdering.latestUpdate(in: grouped[lhs] ?? []) ?? .distantPast
            let rhsDate = AgentSessionOrdering.latestUpdate(in: grouped[rhs] ?? []) ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private var visibleSessions: [AgentSessionSummary] {
        var seen: Set<String> = []
        return (workspaces.flatMap(sessionsForWorkspace) + ungroupedSessions).filter {
            seen.insert($0.id).inserted
        }
    }

    @ViewBuilder
    private func channelSection(_ channel: AgentSessionChannel) -> some View {
        let isExpanded = !collapsedChannelIDs.contains(channel.id)
        let workspaces = hermesWorkspaces(for: channel)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        if isExpanded {
                            collapsedChannelIDs.insert(channel.id)
                        } else {
                            collapsedChannelIDs.remove(channel.id)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "收起\(channel.title)" : "展开\(channel.title)")

                Image(systemName: channel.systemImage)
                    .font(.subheadline.weight(.semibold))
                Text(channel.title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)

            if isExpanded {
                if workspaces.count == 1, let workspace = workspaces.first {
                    ForEach(sessions(in: workspace, channel: channel)) { session in
                        drawerSessionRow(session, workspaceID: workspace.id)
                    }
                } else {
                    ForEach(workspaces) { workspace in
                        hermesWorkspaceSection(workspace, channel: channel)
                    }
                }
            }
        }
    }

    private func dshWorkspaceSection(_ workspace: AgentWorkspace) -> some View {
        let isExpanded = !collapsedWorkspaceIDs.contains(workspace.id)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(workspace.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)

                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        if isExpanded {
                            collapsedWorkspaceIDs.insert(workspace.id)
                        } else {
                            collapsedWorkspaceIDs.remove(workspace.id)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "收起\(workspace.title)" : "展开\(workspace.title)")

                Spacer(minLength: 0)

                Button {
                    onNewConversation(workspace)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("在\(workspace.title)新建聊天")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)

            if isExpanded {
                ForEach(sessionsForWorkspace(workspace)) { session in
                    drawerSessionRow(session, workspaceID: workspace.id)
                }
            }
        }
    }

    private func hermesWorkspaceSection(_ workspace: AgentWorkspace, channel: AgentSessionChannel) -> some View {
        let key = "\(channel.id)|\(workspace.id)"
        let isExpanded = !collapsedWorkspaceIDs.contains(key)
        let sessions = self.sessions(in: workspace, channel: channel)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        if isExpanded {
                            collapsedWorkspaceIDs.insert(key)
                        } else {
                            collapsedWorkspaceIDs.remove(key)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "收起\(workspace.title)" : "展开\(workspace.title)")

                Image(systemName: "folder")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(workspace.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)

                newSessionButton(for: workspace)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)

            if isExpanded {
                ForEach(sessions) { session in
                    drawerSessionRow(session, workspaceID: workspace.id)
                }
            }
        }
    }

    private func sessions(in workspace: AgentWorkspace, channel: AgentSessionChannel) -> [AgentSessionSummary] {
        sessionsForWorkspace(workspace)
            .filter { $0.channel == channel }
            .sorted(by: AgentSessionOrdering.newestFirst)
    }

    private func hermesWorkspaces(for channel: AgentSessionChannel) -> [AgentWorkspace] {
        HermesAgentGateway.workspaces(from: visibleSessions.filter { $0.channel == channel })
    }

    private func newSessionButton(for workspace: AgentWorkspace) -> some View {
        Button {
            onNewConversation(workspace)
        } label: {
            Image(systemName: "plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("在此工作区新建会话")
    }

    private func orderedWorkspaces() -> [AgentWorkspace] {
        workspaces
            .filter { !sessionsForWorkspace($0).isEmpty }
            .sorted { lhs, rhs in
                let lhsSessions = sessionsForWorkspace(lhs)
                let rhsSessions = sessionsForWorkspace(rhs)
                let lhsDate = AgentSessionOrdering.latestUpdate(in: lhsSessions) ?? .distantPast
                let rhsDate = AgentSessionOrdering.latestUpdate(in: rhsSessions) ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    @ViewBuilder
    private func drawerSessionRow(_ session: AgentSessionSummary, workspaceID: String?) -> some View {
        Button {
            onSelectSession(session, workspaceID)
        } label: {
            HStack(spacing: 9) {
                Text(session.title)
                    .font(.callout.weight(selectedSessionID == session.id ? .semibold : .regular))
                    .foregroundStyle(selectedSessionID == session.id ? Color.accentColor : .primary)
                    .lineLimit(1)
                if session.modelProvider == "openai" { Text("openai").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 2).background(Color.blue, in: Capsule()).fixedSize() }
                Spacer(minLength: 4)
                Text(SessionTimestampFormatter.string(for: session.updatedAt))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                Group {
                    if session.isRunning {
                        ProgressView().controlSize(.mini)
                    } else if pendingResponseIDs.contains(session.id),
                              selectedSessionID != session.id {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 8, height: 8)
                    }
                }
                .frame(width: 16, height: 16)
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                selectedSessionID == session.id ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}
