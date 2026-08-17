import SwiftUI

private struct ChatScrollBottomPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ChatSessionView: View {
    @StateObject private var viewModel: ChatSessionViewModel
    @FocusState private var composerFocused: Bool
    @State private var isFollowingLatest = true
    @State private var hasPerformedInitialScroll = false
    private let workspaceTitle: String?
    private let onOpenDrawer: () -> Void
    private let onNewConversation: () -> Void
    private let onConnectionChanged: (Bool, Bool) -> Void
    private let isDrawerGestureActive: Bool

    init(
        profile: ServerProfile,
        password: String,
        session: AgentSessionSummary?,
        workspace: AgentWorkspace?,
        onOpenDrawer: @escaping () -> Void,
        onNewConversation: @escaping () -> Void,
        onSessionCreated: @escaping @MainActor (AgentSessionSummary) -> Void,
        onPromptAccepted: @escaping @MainActor (String) -> Void,
        isDrawerGestureActive: Bool = false,
        onConnectionChanged: @escaping (Bool, Bool) -> Void = { _, _ in }
    ) {
        workspaceTitle = workspace?.title
        self.onOpenDrawer = onOpenDrawer
        self.onNewConversation = onNewConversation
        self.isDrawerGestureActive = isDrawerGestureActive
        self.onConnectionChanged = onConnectionChanged
        _viewModel = StateObject(wrappedValue: ChatSessionViewModel(
            profile: profile,
            password: password,
            session: session,
            workspace: workspace,
            onSessionCreated: onSessionCreated,
            onPromptAccepted: onPromptAccepted
        ))
    }

    var body: some View {
        GeometryReader { container in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 22) {
                        if viewModel.isLoading && viewModel.messages.isEmpty {
                            ProgressView("正在读取会话…")
                                .padding(.top, 80)
                        } else if viewModel.messages.isEmpty {
                            welcomeView
                                .padding(.top, 72)
                        } else {
                            ForEach(viewModel.messages) { message in
                                MessageRow(message: message) { action, payload in
                                    Task { await viewModel.sendGenUIAction(name: action, payload: payload) }
                                }
                                .id(message.id)
                            }
                        }
                        if viewModel.isRunning
                            && viewModel.pendingApproval == nil
                            && viewModel.messages.last?.isStreaming != true {
                            ThinkingIndicator(agentName: viewModel.agentName)
                                .id("thinking-indicator")
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("conversation-bottom")
                            .background(
                                GeometryReader { bottomGeometry in
                                    Color.clear.preference(
                                        key: ChatScrollBottomPreferenceKey.self,
                                        value: bottomGeometry.frame(in: .named("chat-scroll")).maxY
                                    )
                                }
                            )
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .coordinateSpace(name: "chat-scroll")
                .scrollDisabled(isDrawerGestureActive)
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture { composerFocused = false }
                .onPreferenceChange(ChatScrollBottomPreferenceKey.self) { bottomY in
                    let nearBottom = bottomY <= container.size.height + 72
                    if nearBottom != isFollowingLatest {
                        isFollowingLatest = nearBottom
                    }
                }
                .onChange(of: viewModel.messages) { _, _ in
                    if !hasPerformedInitialScroll && !viewModel.isLoading {
                        scheduleScrollToLatest(using: proxy, force: true)
                    } else {
                        scheduleScrollToLatest(using: proxy)
                    }
                }
                .onChange(of: viewModel.isLoading) { _, isLoading in
                    guard !isLoading, !viewModel.messages.isEmpty, !hasPerformedInitialScroll else { return }
                    scheduleScrollToLatest(using: proxy, force: true)
                }
                .onChange(of: viewModel.isRunning) { _, _ in
                    scheduleScrollToLatest(using: proxy)
                }
                .onChange(of: viewModel.pendingApprovals) { _, _ in
                    scheduleScrollToLatest(using: proxy)
                }
                .onChange(of: composerFocused) { _, focused in
                    if focused {
                        guard isFollowingLatest else { return }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(220))
                            guard composerFocused else { return }
                            scheduleScrollToLatest(using: proxy, force: true)
                        }
                    } else {
                        guard isFollowingLatest else { return }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(150))
                            scheduleScrollToLatest(using: proxy, force: true)
                        }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !viewModel.messages.isEmpty && !isFollowingLatest {
                        Button {
                            scheduleScrollToLatest(using: proxy, force: true)
                        } label: {
                            Label("回到底部", systemImage: "arrow.down")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .shadow(color: .black.opacity(0.12), radius: 7, y: 3)
                        .padding(.trailing, 18)
                        .padding(.bottom, 18)
                    }
                }
            }
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) { chatHeader }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) {
            if let error = viewModel.errorMessage {
                ErrorBanner(message: error) { viewModel.errorMessage = nil }
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task { viewModel.start() }
        .onChange(of: viewModel.isConnected) { _, connected in
            onConnectionChanged(connected, viewModel.isReconnecting)
        }
        .onChange(of: viewModel.isReconnecting) { _, reconnecting in
            onConnectionChanged(viewModel.isConnected, reconnecting)
        }
        .onDisappear { viewModel.stop() }
    }

    private func scheduleScrollToLatest(using proxy: ScrollViewProxy, force: Bool = false) {
        guard force || isFollowingLatest else { return }
        Task { @MainActor in
            await Task.yield()
            await Task.yield()
            guard force || isFollowingLatest else { return }
            if force {
                isFollowingLatest = true
                hasPerformedInitialScroll = true
            }
            proxy.scrollTo("conversation-bottom", anchor: .bottom)
        }
    }

    private var chatHeader: some View {
        HStack(spacing: 12) {
            Button(action: onOpenDrawer) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(Color.primary.opacity(0.05), in: Circle())
            }
            .accessibilityLabel("打开会话列表")

            Spacer(minLength: 0)
            VStack(spacing: 1) {
                Text(viewModel.title)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Circle()
                        .fill(viewModel.isConnected ? Color.green : Color.secondary)
                        .frame(width: 5, height: 5)
                    Text(viewModel.isConnected ? "已连接" : (viewModel.isReconnecting ? "正在重连" : "正在连接"))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
            Button(action: onNewConversation) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(Color.primary.opacity(0.05), in: Circle())
            }
            .accessibilityLabel("新建会话")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(uiColor: .systemBackground))
    }

    private var welcomeView: some View {
        VStack(spacing: 16) {
            AgentLogoView(kind: viewModel.agentKind, size: 68)
            Text("有什么需要处理？")
                .font(.title2.weight(.semibold))
            Text(workspaceTitle.map { "将在\u{300C}\($0)\u{300D}工作区开始" } ?? "消息会直接发送给远程服务器上的 \(viewModel.agentName)。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("给 \(viewModel.agentName) 发消息", text: $viewModel.composerText, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .padding(.leading, 15)
                    .padding(.vertical, 11)

                if viewModel.isRunning {
                    Button { Task { await viewModel.cancel() } } label: {
                        ZStack {
                            Circle().fill(Color.primary)
                            if viewModel.isStopping {
                                ProgressView().tint(Color(uiColor: .systemBackground))
                            } else {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Color(uiColor: .systemBackground))
                            }
                        }
                        .frame(width: 36, height: 36)
                    }
                    .disabled(viewModel.isStopping)
                    .accessibilityLabel("停止生成")
                    .padding(.trailing, 5)
                    .padding(.bottom, 4)
                } else {
                    Button { Task { await viewModel.send() } } label: {
                        ZStack {
                            Circle().fill(canSend ? Color.accentColor : Color.secondary.opacity(0.25))
                            Image(systemName: "arrow.up")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 36, height: 36)
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("发送")
                    .padding(.trailing, 5)
                    .padding(.bottom, 4)
                }
            }
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            if viewModel.isRunning {
                Text("\(viewModel.agentName) 正在处理；如需发送下一条，请先停止当前生成。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .background(Color(uiColor: .systemBackground))
    }

    @ViewBuilder
    private var bottomBar: some View {
        if let approval = viewModel.pendingApproval {
            ApprovalComposerPanel(
                approval: approval,
                pendingCount: viewModel.pendingApprovals.count,
                isResponding: viewModel.respondingApprovalID == approval.id,
                onChoice: { choice in
                    Task { await viewModel.respond(to: approval, choice: choice) }
                }
            )
        } else {
            composer
        }
    }

    private var canSend: Bool {
        !viewModel.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
