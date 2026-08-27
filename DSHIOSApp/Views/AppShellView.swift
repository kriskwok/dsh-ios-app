import SwiftUI
import UIKit

struct AppShellView: View {
    @EnvironmentObject private var serverStore: ServerStore
    @StateObject private var viewModel = AppShellViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var drawerProgress: CGFloat = 0
    @GestureState private var dragTranslation: CGFloat = 0
    @State private var drawerDragStartProgress: CGFloat?
    @State private var drawerDragAxis: DrawerDragAxis?
    @State private var isHorizontalDrawerDragActive = false
    @State private var showsServerSettings = false
    @State private var chatIsConnected = false
    @State private var chatIsReconnecting = false
    @State private var modelSelectorIsActive = false
    @State private var sessionToRename: AgentSessionSummary?
    @State private var renameText = ""
    @State private var sessionToArchive: AgentSessionSummary?

    var body: some View {
        GeometryReader { geometry in
            let drawerWidth = min(geometry.size.width * 0.85, 380)
            let visualProgress = DrawerMotion.clamped(drawerProgress + dragTranslation)
            let translateX = -drawerWidth * (1 - visualProgress)

            HStack(spacing: 0) {
                ConversationDrawerView(
                    profile: serverStore.selectedProfile,
                    profiles: serverStore.enabledProfiles,
                    workspaces: viewModel.workspaces,
                    sessionsForWorkspace: viewModel.sessions(in:),
                    ungroupedSessions: viewModel.ungroupedSessions,
                    selectedSessionID: viewModel.target.session?.id,
                    pendingResponseIDs: viewModel.pendingResponseIDs,
                    isLoading: viewModel.isLoading,
                    errorMessage: viewModel.errorMessage,
                    isConnected: chatIsConnected,
                    isReconnecting: chatIsReconnecting,
                    isDrawerGestureActive: isHorizontalDrawerDragActive,
                    onNewConversation: { workspace in
                        viewModel.startNewConversation(workspace: workspace)
                        closeDrawer()
                    },
                    onSelectSession: { session, workspaceID in
                        // Selecting the already-current session just closes the
                        // drawer — do not mutate target, or the session view
                        // would reload and lose its scroll position.
                        guard session.id != viewModel.target.session?.id else {
                            closeDrawer()
                            return
                        }
                        viewModel.selectSession(session, workspaceID: workspaceID)
                        closeDrawer()
                    },
                    onRefresh: { await viewModel.load() },
                    onOpenSettings: { showsServerSettings = true },
                    onSelectServer: { profile in
                        serverStore.select(profile)
                        closeDrawer()
                    },
                    onRenameSession: { session in
                        sessionToRename = session
                        renameText = session.title
                    },
                    onArchiveSession: { session in
                        sessionToArchive = session
                    }
                )
                .frame(width: drawerWidth)
                // Block touches on the drawer list while a horizontal drag is active,
                // so a swipe-to-close never accidentally selects a session.
                .overlay {
                    if isHorizontalDrawerDragActive {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { }
                    }
                }

                ZStack {
                    Color(uiColor: .systemBackground)
                    NavigationStack {
                        homeContent
                    }
                }
                .frame(width: geometry.size.width)
                .overlay {
                    // When the drawer is open or being dragged, cover the session
                    // page so it cannot scroll or receive any touches.
                    if visualProgress > 0 || isHorizontalDrawerDragActive {
                        Color.black.opacity(visualProgress > 0 ? 0.24 * visualProgress : 0)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { closeDrawer() }
                            .gesture(DragGesture())
                    }
                }
                .accessibilityHidden(visualProgress > 0.95)
            }
            .offset(x: translateX)
            .contentShape(Rectangle())
            .simultaneousGesture(
                modelSelectorIsActive ? nil : drawerGesture(width: drawerWidth)
            )
        }
        .sheet(isPresented: $showsServerSettings) {
            ServerSettingsView { profile in
                serverStore.select(profile)
                showsServerSettings = false
                closeDrawer()
            }
            .environmentObject(serverStore)
        }
        .alert("重命名会话", isPresented: Binding(
            get: { sessionToRename != nil },
            set: { if !$0 { sessionToRename = nil } }
        )) {
            TextField("会话名称", text: $renameText)
            Button("取消", role: .cancel) { sessionToRename = nil }
            Button("保存") {
                if let session = sessionToRename {
                    Task { await viewModel.renameSession(session, title: renameText) }
                }
                sessionToRename = nil
            }
        } message: {
            Text("输入新的会话名称")
        }
        .alert("归档会话", isPresented: Binding(
            get: { sessionToArchive != nil },
            set: { if !$0 { sessionToArchive = nil } }
        )) {
            Button("取消", role: .cancel) { sessionToArchive = nil }
            Button("归档", role: .destructive) {
                if let session = sessionToArchive {
                    Task { await viewModel.archiveSession(session, archived: true) }
                }
                sessionToArchive = nil
            }
        } message: {
            Text("确定要归档「\(sessionToArchive?.title ?? "")」吗？归档后该会话将从列表中隐藏。")
        }
        .alert("操作失败", isPresented: Binding(
            get: { viewModel.operationError != nil },
            set: { if !$0 { viewModel.operationError = nil } }
        )) {
            Button("确定") { viewModel.operationError = nil }
        } message: {
            Text(viewModel.operationError ?? "")
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await viewModel.load() }
            }
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
                    Task { await viewModel.load() }
                },
                onPromptAccepted: { sessionID in
                    viewModel.markSessionStarted(sessionID, targetID: target.id)
                    Task { await viewModel.load() }
                },
                isDrawerGestureActive: isHorizontalDrawerDragActive || drawerProgress > 0,
                onConnectionChanged: { connected, reconnecting in
                    chatIsConnected = connected
                    chatIsReconnecting = reconnecting
                },
                onModelSelectorChanged: { active in
                    modelSelectorIsActive = active
                },
                onRunningChanged: { isRunning in
                    if let sessionID = target.session?.id {
                        viewModel.updateSessionRunning(sessionID, isRunning: isRunning)
                    }
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
        DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .updating($dragTranslation) { value, state, _ in
                if drawerDragAxis == nil {
                    let horizontalDistance = abs(value.translation.width)
                    let verticalDistance = abs(value.translation.height)
                    guard max(horizontalDistance, verticalDistance) >= 8 else { return }
                    // When the drawer is closed, only swipes starting in the left
                    // third of the screen may open it — so horizontal scrolling
                    // inside session content (e.g. wide tables) is untouched.
                    if drawerProgress == 0 && value.startLocation.x > width / 3 {
                        drawerDragAxis = .vertical
                        return
                    }
                    drawerDragAxis = horizontalDistance >= verticalDistance ? .horizontal : .vertical
                    isHorizontalDrawerDragActive = drawerDragAxis == .horizontal
                    if drawerDragAxis == .horizontal {
                        // Dismiss the keyboard as soon as a horizontal drag begins.
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    }
                }
                guard drawerDragAxis == .horizontal else { return }
                if drawerDragStartProgress == nil {
                    drawerDragStartProgress = drawerProgress
                }
                guard let start = drawerDragStartProgress else { return }
                state = DrawerMotion.clamped(start + value.translation.width / width) - start
            }
            .onEnded { value in
                let wasHorizontal = drawerDragAxis == .horizontal
                let startProgress = drawerDragStartProgress
                drawerDragAxis = nil
                drawerDragStartProgress = nil
                guard wasHorizontal, let start = startProgress else {
                    isHorizontalDrawerDragActive = false
                    return
                }
                let current = DrawerMotion.clamped(start + value.translation.width / width)
                let predicted = DrawerMotion.clamped(start + value.predictedEndTranslation.width / width)
                let target = DrawerMotion.targetProgress(current: current, predicted: predicted)
                // Snap to current position first (no animation) to avoid the @GestureState
                // reset causing a visible jump, then animate to the target.
                drawerProgress = current
                settleDrawer(at: target)
                // Delay re-enabling drawer list interaction so the finger-lift
                // does not register as a tap on a session row.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    isHorizontalDrawerDragActive = false
                }
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
