import SwiftUI
import UIKit

struct AppShellView: View {
    @EnvironmentObject private var serverStore: ServerStore
    @StateObject private var viewModel = AppShellViewModel()
    @State private var drawerProgress: CGFloat = 0
    @State private var drawerDragStartProgress: CGFloat?
    @State private var drawerDragAxis: DrawerDragAxis?
    @State private var isHorizontalDrawerDragActive = false
    @State private var showsServerSettings = false
    @State private var chatIsConnected = false
    @State private var chatIsReconnecting = false

    var body: some View {
        GeometryReader { geometry in
            let drawerWidth = min(geometry.size.width * 0.85, 380)
            let drawerOffset = -drawerWidth * (1 - drawerProgress)

            ZStack(alignment: .leading) {
                NavigationStack {
                    homeContent
                }
                .scaleEffect(1 - max(0, drawerProgress) * 0.025, anchor: .trailing)
                .allowsHitTesting(drawerProgress < 0.01)
                .accessibilityHidden(drawerProgress > 0.95)

                if drawerProgress > 0 {
                    Color.black.opacity(0.24 * drawerProgress)
                        .ignoresSafeArea()
                        .onTapGesture { closeDrawer() }
                }

                ConversationDrawerView(
                    profile: serverStore.selectedProfile,
                    workspaces: viewModel.workspaces,
                    sessionsForWorkspace: viewModel.sessions(in:),
                    ungroupedSessions: viewModel.ungroupedSessions,
                    selectedSessionID: viewModel.target.session?.id,
                    isLoading: viewModel.isLoading,
                    errorMessage: viewModel.errorMessage,
                    isConnected: chatIsConnected,
                    isReconnecting: chatIsReconnecting,
                    isDrawerGestureActive: isHorizontalDrawerDragActive,
                    onNewConversation: { workspaceID in
                        viewModel.startNewConversation(workspaceID: workspaceID)
                        closeDrawer()
                    },
                    onSelectSession: { session, workspaceID in
                        viewModel.selectSession(session, workspaceID: workspaceID)
                        closeDrawer()
                    },
                    onRefresh: { await viewModel.load() },
                    onOpenSettings: { showsServerSettings = true }
                )
                .frame(width: drawerWidth)
                .offset(x: drawerOffset)
                .shadow(color: .black.opacity(0.16 * drawerProgress), radius: 20, x: 8)
                .accessibilityHidden(drawerProgress < 0.01)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(drawerGesture(width: drawerWidth))
        }
        .sheet(isPresented: $showsServerSettings) {
            ServerSettingsView { profile in
                serverStore.select(profile)
                showsServerSettings = false
                closeDrawer()
            }
            .environmentObject(serverStore)
        }
        .task(id: configurationKey) {
            chatIsConnected = false
            chatIsReconnecting = false
            guard let profile = serverStore.selectedProfile else { return }
            await viewModel.configure(
                profile: profile,
                password: serverStore.password(for: profile) ?? ""
            )
        }
    }

    @ViewBuilder
    private var homeContent: some View {
        if let profile = serverStore.selectedProfile {
            let target = viewModel.target
            ChatSessionView(
                profile: profile,
                password: serverStore.password(for: profile) ?? "",
                session: target.session,
                workspace: viewModel.workspaces.first(where: { $0.id == target.workspaceID }),
                onOpenDrawer: openDrawer,
                onNewConversation: { viewModel.startNewConversation() },
                onSessionCreated: { session in
                    viewModel.attachCreatedSession(session, to: target.id)
                },
                onPromptAccepted: { sessionID in
                    viewModel.markSessionStarted(sessionID, targetID: target.id)
                    Task { await viewModel.load() }
                },
                isDrawerGestureActive: isHorizontalDrawerDragActive,
                onConnectionChanged: { connected, reconnecting in
                    chatIsConnected = connected
                    chatIsReconnecting = reconnecting
                }
            )
            .id(target.id)
        } else {
            EmptyChatHomeView(
                onOpenDrawer: openDrawer,
                onOpenSettings: { showsServerSettings = true }
            )
        }
    }

    private var configurationKey: String {
        "\(serverStore.selectedProfileID?.uuidString ?? "none")-\(serverStore.revision)"
    }

    private func drawerGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .local)
            .onChanged { value in
                if drawerDragAxis == nil {
                    let horizontalDistance = abs(value.translation.width)
                    let verticalDistance = abs(value.translation.height)
                    guard max(horizontalDistance, verticalDistance) >= 8 else { return }
                    drawerDragAxis = horizontalDistance >= verticalDistance ? .horizontal : .vertical
                    isHorizontalDrawerDragActive = drawerDragAxis == .horizontal
                }
                guard drawerDragAxis == .horizontal else { return }
                if drawerDragStartProgress == nil {
                    drawerDragStartProgress = drawerProgress
                }
                guard let start = drawerDragStartProgress else { return }
                drawerProgress = DrawerMotion.clamped(start + value.translation.width / width)
            }
            .onEnded { value in
                defer {
                    drawerDragAxis = nil
                    drawerDragStartProgress = nil
                    isHorizontalDrawerDragActive = false
                }
                guard drawerDragAxis == .horizontal,
                      let start = drawerDragStartProgress else { return }
                let predicted = DrawerMotion.clamped(start + value.predictedEndTranslation.width / width)
                let target = DrawerMotion.targetProgress(current: drawerProgress, predicted: predicted)
                settleDrawer(at: target)
            }
    }

    private func openDrawer() {
        settleDrawer(at: 1)
        Task { await viewModel.load() }
    }

    private func closeDrawer() {
        settleDrawer(at: 0)
    }

    private func settleDrawer(at progress: CGFloat) {
        let target = DrawerMotion.clamped(progress)
        let wasOpen = drawerProgress > 0.99
        let wasClosed = drawerProgress < 0.01
        let shouldGiveFeedback = (target >= 0.99 && !wasOpen) || (target <= 0.01 && !wasClosed)
        drawerDragAxis = nil
        drawerDragStartProgress = nil
        isHorizontalDrawerDragActive = false
        withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.9, blendDuration: 0.1)) {
            drawerProgress = target
        }
        if shouldGiveFeedback {
            let feedback = UIImpactFeedbackGenerator(style: .light)
            feedback.prepare()
            feedback.impactOccurred()
        }
    }
}

private enum DrawerDragAxis {
    case horizontal
    case vertical
}

enum DrawerMotion {
    static func clamped(_ progress: CGFloat) -> CGFloat {
        min(1, max(0, progress))
    }

    static func targetProgress(current: CGFloat, predicted: CGFloat) -> CGFloat {
        let projected = clamped(predicted)
        if abs(projected - current) < 0.08 {
            return current >= 0.5 ? 1 : 0
        }
        return projected >= 0.5 ? 1 : 0
    }
}

private struct ConversationDrawerView: View {
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
            .padding(.leading, workspaceID == nil ? 16 : 24)
            .padding(.trailing, 10)
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

private struct EmptyChatHomeView: View {
    let onOpenDrawer: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "server.rack")
                .font(.system(size: 38))
                .foregroundStyle(Color.accentColor)
            Text("添加 Agent 服务器")
                .font(.title2.weight(.semibold))
            Text("添加服务器后，这里会直接显示新会话窗口。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("打开服务器设置", action: onOpenSettings)
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
        .safeAreaInset(edge: .top) {
            HStack {
                Button(action: onOpenDrawer) {
                    Image(systemName: "line.3.horizontal")
                        .frame(width: 38, height: 38)
                }
                .accessibilityLabel("打开会话列表")
                Spacer()
            }
            .padding(.horizontal, 12)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}
