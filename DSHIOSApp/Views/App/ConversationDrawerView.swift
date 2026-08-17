import SwiftUI

struct ConversationDrawerView: View {
    let profile: ServerProfile?
    let workspaces: [AgentWorkspace]
    let sessionsForWorkspace: (AgentWorkspace) -> [AgentSessionSummary]
    let ungroupedSessions: [AgentSessionSummary]
    let selectedSessionID: String?
    let isLoading: Bool
    let errorMessage: String?
    let isConnected: Bool
    let isReconnecting: Bool
    let isDrawerGestureActive: Bool
    let onNewConversation: (String?) -> Void
    let onSelectSession: (AgentSessionSummary, String?) -> Void
    let onRefresh: () async -> Void
    let onOpenSettings: () -> Void

    @State private var collapsedWorkspaceIDs: Set<String> = []
    @State private var collapsedChannelIDs: Set<String> = ["automation"]

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
                    Text(profile?.name ?? "Agent")
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
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
                    LazyVStack(alignment: .leading, spacing: 8) {
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
                                workspaceSection(workspace, channel: nil)
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
                .padding(.leading, horizontalPadding + logoSize + logoSpacing)
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

    private var channelSections: [AgentSessionChannel] {
        let grouped = Dictionary(grouping: visibleSessions, by: \.channel)
        return grouped.keys.sorted { lhs, rhs in
            let lhsDate = AgentSessionOrdering.latestUpdate(in: grouped[lhs] ?? []) ?? .distantPast
            let rhsDate = AgentSessionOrdering.latestUpdate(in: grouped[rhs] ?? []) ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
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
        DisclosureGroup(isExpanded: channelExpansionBinding(for: channel.id)) {
            ForEach(orderedWorkspaces(for: channel)) { workspace in
                workspaceSection(workspace, channel: channel)
            }

            ForEach(ungroupedSessions.filter { $0.channel == channel }.sorted(by: AgentSessionOrdering.newestFirst)) { session in
                drawerSessionRow(session, workspaceID: nil)
            }
        } label: {
            Label(channel.title, systemImage: channel.systemImage)
                .font(.subheadline.weight(.semibold))
        }
        .tint(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func workspaceSection(_ workspace: AgentWorkspace, channel: AgentSessionChannel?) -> some View {
        if let channel {
            hermesWorkspaceSection(workspace, channel: channel)
        } else {
            dshWorkspaceSection(workspace)
        }
    }

    private func dshWorkspaceSection(_ workspace: AgentWorkspace) -> some View {
        let isExpanded = !collapsedWorkspaceIDs.contains(workspace.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(workspace.title)
                    .font(.subheadline.weight(.semibold))
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
                    onNewConversation(workspace.id)
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
        let sessions = self.sessions(in: workspace, channel: channel)
        return DisclosureGroup(isExpanded: expansionBinding(for: key)) {
            Button {
                onNewConversation(workspace.id)
            } label: {
                Label("在此工作区新建 iPhone 对话", systemImage: "plus")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)

            ForEach(sessions) { session in
                drawerSessionRow(session, workspaceID: workspace.id)
            }
        } label: {
            Label(workspace.title, systemImage: "folder")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .tint(.primary)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
    }

    private func sessions(in workspace: AgentWorkspace, channel: AgentSessionChannel) -> [AgentSessionSummary] {
        sessionsForWorkspace(workspace)
            .filter { $0.channel == channel }
            .sorted(by: AgentSessionOrdering.newestFirst)
    }

    private func orderedWorkspaces(for channel: AgentSessionChannel? = nil) -> [AgentWorkspace] {
        workspaces
            .filter { workspace in
                guard let channel else { return true }
                return !sessions(in: workspace, channel: channel).isEmpty
            }
            .sorted { lhs, rhs in
                let lhsSessions = channel.map { sessions(in: lhs, channel: $0) } ?? sessionsForWorkspace(lhs)
                let rhsSessions = channel.map { sessions(in: rhs, channel: $0) } ?? sessionsForWorkspace(rhs)
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
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(SessionTimestampFormatter.string(for: session.updatedAt))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                if session.isRunning {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                selectedSessionID == session.id ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func expansionBinding(for workspaceID: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedWorkspaceIDs.contains(workspaceID) },
            set: { expanded in
                if expanded {
                    collapsedWorkspaceIDs.remove(workspaceID)
                } else {
                    collapsedWorkspaceIDs.insert(workspaceID)
                }
            }
        )
    }

    private func channelExpansionBinding(for channelID: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedChannelIDs.contains(channelID) },
            set: { expanded in
                if expanded {
                    collapsedChannelIDs.remove(channelID)
                } else {
                    collapsedChannelIDs.insert(channelID)
                }
            }
        )
    }
}
