import SwiftUI
import UIKit

struct AppShellView: View {
    @EnvironmentObject private var serverStore: ServerStore
    @StateObject private var viewModel = AppShellViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var drawerProgress: CGFloat = 0
    @State private var drawerDragStartProgress: CGFloat?
    @State private var drawerDragAxis: DrawerDragAxis?
    @State private var isHorizontalDrawerDragActive = false
    @State private var showsServerSettings = false
    @State private var chatIsConnected = false
    @State private var chatIsReconnecting = false
    @State private var modelSelectorIsActive = false

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
                    pendingResponseIDs: viewModel.pendingResponseIDs,
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
                },
                onPromptAccepted: { sessionID in
                    viewModel.markSessionStarted(sessionID, targetID: target.id)
                    Task { await viewModel.load() }
                },
                isDrawerGestureActive: isHorizontalDrawerDragActive,
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
