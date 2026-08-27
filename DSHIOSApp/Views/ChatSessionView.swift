import SwiftUI

private struct ChatScrollBottomPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ChatSessionView: View {
    @StateObject private var viewModel: ChatSessionViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var composerFocused: Bool
    @State private var isFollowingLatest = true
    @State private var hasPerformedInitialScroll = false
    @State private var showModelSelector = false
    @State private var showPermissionPicker = false
    @State private var pendingPermissionPreset: String?
    @State private var showUploadOptions = false
    @State private var showCamera = false
    @State private var showPhotoLibrary = false
    @State private var showDocumentPicker = false
    private let workspaceTitle: String?
    private let sessionID: String?
    private let onOpenDrawer: () -> Void
    private let onNewConversation: () -> Void
    private let onConnectionChanged: (Bool, Bool) -> Void
    private let isDrawerGestureActive: Bool
    private let onModelSelectorChanged: (Bool) -> Void
    private let onRunningChanged: (Bool) -> Void
    private let basicAuthToken: String?

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
        onConnectionChanged: @escaping (Bool, Bool) -> Void = { _, _ in },
        onModelSelectorChanged: @escaping (Bool) -> Void = { _ in },
        onRunningChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        workspaceTitle = workspace?.title
        sessionID = session?.id
        self.onOpenDrawer = onOpenDrawer
        self.onNewConversation = onNewConversation
        self.isDrawerGestureActive = isDrawerGestureActive
        self.onConnectionChanged = onConnectionChanged
        self.onModelSelectorChanged = onModelSelectorChanged
        self.onRunningChanged = onRunningChanged
        basicAuthToken = profile.username.isEmpty ? nil : Data("\(profile.username):\(password)".utf8).base64EncodedString()
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
                    LazyVStack(spacing: 24) {
                        if viewModel.isLoading && viewModel.messages.isEmpty {
                            ProgressView("正在读取会话…")
                                .padding(.top, 80)
                        } else if viewModel.messages.isEmpty {
                            welcomeView
                                .padding(.top, 72)
                        } else {
                            ForEach(viewModel.messages) { message in
                                MessageRow(
                                    message: message,
                                    onDSHUIAction: { action, payload in
                                        Task { await viewModel.sendGenUIAction(name: action, payload: payload) }
                                    },
                                    attachmentLoader: { attachmentId, id, ext in
                                        await viewModel.fetchAttachmentData(attachmentId: attachmentId, id: id, ext: ext)
                                    },
                                    remoteFileLoader: { path in
                                        await viewModel.fetchRemoteFileData(path: path)
                                    }
                                )
                                .id(message.id)
                            }
                        }
                        if viewModel.isRunning
                            && viewModel.pendingApproval == nil
                            && viewModel.pendingQuestion == nil
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
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                }
                .coordinateSpace(name: "chat-scroll")
                .scrollDisabled(isDrawerGestureActive)
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture { composerFocused = false }
                .onPreferenceChange(ChatScrollBottomPreferenceKey.self) { bottomY in
                    guard !isDrawerGestureActive else { return }
                    let nearBottom = bottomY <= container.size.height + 72
                    if nearBottom != isFollowingLatest {
                        isFollowingLatest = nearBottom
                    }
                }
                .onChange(of: viewModel.messages) { _, _ in
                    if !hasPerformedInitialScroll && !viewModel.messages.isEmpty {
                        scheduleScrollToLatest(using: proxy, force: true)
                    } else {
                        scheduleScrollToLatest(using: proxy)
                    }
                }
                .onChange(of: viewModel.isLoading) { _, isLoading in
                    guard !isLoading, !viewModel.messages.isEmpty, !hasPerformedInitialScroll else { return }
                    scheduleScrollToLatest(using: proxy, force: true)
                }
                .onChange(of: sessionID) { _, _ in
                    // Reset scroll state when switching to a different session.
                    hasPerformedInitialScroll = false
                    isFollowingLatest = true
                }
                .onChange(of: viewModel.isRunning) { _, isRunning in
                    onRunningChanged(isRunning)
                    scheduleScrollToLatest(using: proxy)
                }
                .onChange(of: viewModel.pendingApprovals) { _, _ in
                    scheduleScrollToLatest(using: proxy)
                }
                .onChange(of: viewModel.pendingQuestions) { _, _ in
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
                .onChange(of: isDrawerGestureActive) { _, active in
                    guard active, isFollowingLatest else { return }
                    Task { @MainActor in
                        await Task.yield()
                        await Task.yield()
                        proxy.scrollTo("conversation-bottom", anchor: .bottom)
                    }
                }
                .onAppear {
                    if !hasPerformedInitialScroll && !viewModel.messages.isEmpty {
                        scheduleScrollToLatest(using: proxy, force: true)
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
        .overlay(alignment: .bottom) {
            if showModelSelector && viewModel.canSelectModel {
                ZStack(alignment: .bottomTrailing) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showModelSelector = false
                            }
                        }

                    ModelSelectorPopover(viewModel: viewModel, isPresented: $showModelSelector)
                        .padding(.trailing, 12)
                        .padding(.bottom, 60)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        .overlay(alignment: .bottom) {
            if showPermissionPicker && !viewModel.permissionOptions.isEmpty {
                ZStack(alignment: .bottomLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showPermissionPicker = false
                            }
                        }

                    permissionPicker
                        .padding(.leading, 20)
                        .padding(.bottom, 60)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        .alert("切换到完全权限？", isPresented: Binding(
            get: { pendingPermissionPreset != nil },
            set: { if !$0 { pendingPermissionPreset = nil } }
        )) {
            Button("取消", role: .cancel) { pendingPermissionPreset = nil }
            Button("确认切换", role: .destructive) {
                if let preset = pendingPermissionPreset {
                    Task { await viewModel.setPermission(preset) }
                }
                pendingPermissionPreset = nil
                withAnimation(.easeInOut(duration: 0.2)) { showPermissionPicker = false }
            }
        } message: {
            Text("完全权限将允许 Agent 无限制地访问文件系统且不再弹出审批确认，请确认你信任当前会话的操作。")
        }
        .overlay(alignment: .top) {
            if let toast = viewModel.permissionToast {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("权限已切换为：\(toast)")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(.primary.opacity(0.1), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(100)
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureView(
                onCapture: { image in
                    viewModel.addComposerImage(image)
                    showCamera = false
                },
                onClose: { showCamera = false }
            )
        }
        .fullScreenCover(isPresented: $showPhotoLibrary) {
            PhotoLibraryPicker(
                onSubmit: { images in
                    for image in images {
                        viewModel.addComposerImage(image)
                    }
                    showPhotoLibrary = false
                },
                onClose: { showPhotoLibrary = false }
            )
        }
        .fullScreenCover(isPresented: $showDocumentPicker) {
            DocumentPicker(
                onPick: { urls in
                    for url in urls {
                        viewModel.addComposerFile(url: url)
                    }
                    showDocumentPicker = false
                },
                onCancel: { showDocumentPicker = false }
            )
        }
        .task { viewModel.start() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                if viewModel.hasStarted && !viewModel.isConnected && !viewModel.isReconnecting {
                    viewModel.reconnect()
                } else if viewModel.hasStarted && viewModel.isConnected {
                    Task { await viewModel.loadModels() }
                }
            case .background, .inactive:
                showModelSelector = false
                showPermissionPicker = false
            @unknown default:
                break
            }
        }
        .onChange(of: viewModel.isConnected) { _, connected in
            onConnectionChanged(connected, viewModel.isReconnecting)
        }
        .onChange(of: showModelSelector) { _, show in
            onModelSelectorChanged(show)
        }
        .onChange(of: viewModel.isReconnecting) { _, reconnecting in
            onConnectionChanged(viewModel.isConnected, reconnecting)
        }
        .onDisappear { viewModel.stop() }
        .environment(\.basicAuthToken, basicAuthToken)
    }

    private func scheduleScrollToLatest(using proxy: ScrollViewProxy, force: Bool = false) {
        guard force || (isFollowingLatest && !isDrawerGestureActive) else { return }
        Task { @MainActor in
            await Task.yield()
            await Task.yield()
            // For the initial forced scroll, add a small delay to ensure the
            // content (especially images and long text) is fully laid out
            // before scrolling, otherwise the ScrollView may end up past the
            // content and show a blank screen.
            if force {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
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
                Image(systemName: "sidebar.left")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .foregroundStyle(.primary)
            .accessibilityLabel("打开会话列表")

            Spacer(minLength: 0)
            Text(viewModel.title)
                .font(.headline)
                .lineLimit(1)

            Spacer(minLength: 0)
            Button(action: onNewConversation) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .foregroundStyle(.primary)
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

    private var modelSelectorButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                showModelSelector.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                if viewModel.isModelLoading {
                    ProgressView()
                        .scaleEffect(0.65)
                        .frame(width: 12, height: 12)
                } else if let name = viewModel.currentModelDisplayName {
                    Text(name.count > 20 ? String(name.prefix(18)) + "…" : name)
                        .lineLimit(1)
                    if !viewModel.isCurrentModelAvailable {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("选择模型")
                        .foregroundStyle(.secondary)
                }
                Image(systemName: showModelSelector ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(showModelSelector ? Color.accentColor.opacity(0.1) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var sendButton: some View {
        Group {
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
                    .frame(width: 34, height: 34)
                }
                .disabled(viewModel.isStopping)
                .accessibilityLabel("停止生成")
            } else {
                Button { composerFocused = false; showUploadOptions = false; Task { await viewModel.send() } } label: {
                    ZStack {
                        Circle().fill(canSend ? Color.accentColor : Color.secondary.opacity(0.25))
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 34, height: 34)
                }
                .disabled(!canSend)
                .accessibilityLabel("发送")
            }
        }
    }

    private func permissionIcon(_ value: String?) -> String {
        switch value {
        case "read-only": return "checkmark.shield"
        case "workspace-write": return "pencil.and.outline"
        case "danger-full-access": return "exclamationmark.shield"
        default: return "shield"
        }
    }

    private func permissionLabel(_ value: String) -> String {
        switch value {
        case "read-only": return "仅可查看"
        case "workspace-write": return "可写入工作区"
        case "danger-full-access": return "完全权限"
        default: return value
        }
    }

    private var permissionButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                showPermissionPicker.toggle()
            }
        } label: {
            Image(systemName: permissionIcon(viewModel.currentPermission))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
    }

    private var permissionPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(viewModel.permissionOptions, id: \.value) { option in
                Button {
                    if option.value == viewModel.currentPermission {
                        withAnimation(.easeInOut(duration: 0.2)) { showPermissionPicker = false }
                        return
                    }
                    if option.value == "danger-full-access" {
                        pendingPermissionPreset = option.value
                    } else {
                        Task { await viewModel.setPermission(option.value) }
                        withAnimation(.easeInOut(duration: 0.2)) { showPermissionPicker = false }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: permissionIcon(option.value))
                            .font(.system(size: 16))
                            .foregroundStyle(.primary)
                            .frame(width: 22)
                        Text(permissionLabel(option.value))
                            .font(.body)
                            .foregroundStyle(.primary)
                        Spacer()
                        if viewModel.currentPermission == option.value {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if option.value != viewModel.permissionOptions.last?.value {
                    Divider().padding(.horizontal, 14)
                }
            }
        }
        .frame(width: 220)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
    }

    private var isComposerCollapsed: Bool {
        !composerFocused
            && viewModel.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && viewModel.composerAttachments.isEmpty
            && !showUploadOptions
    }

    private var composer: some View {
        VStack(spacing: 0) {
            // Attachment preview strip
            ComposerAttachmentStrip(viewModel: viewModel)

            HStack(alignment: isComposerCollapsed ? .center : .bottom, spacing: 8) {
                TextField("给 \(viewModel.agentName) 发消息", text: $viewModel.composerText, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                if isComposerCollapsed {
                    sendButton
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, isComposerCollapsed ? 10 : 0)
            .padding(.top, isComposerCollapsed ? 0 : 11)
            .padding(.bottom, isComposerCollapsed ? 0 : 4)

            if !isComposerCollapsed {
                HStack(spacing: 8) {
                    // + button (left of permission button)
                    plusButton

                    if !viewModel.permissionOptions.isEmpty {
                        permissionButton
                    }
                    Spacer()
                    if let cacheHitRatio = viewModel.cacheHitRatio {
                        Text("缓存 \(Int((cacheHitRatio * 100).rounded()))%")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    if viewModel.canSelectModel {
                        modelSelectorButton
                    }
                    if let contextUsageRatio = viewModel.contextUsageRatio {
                        ContextUsageRing(
                            progress: min(max(contextUsageRatio, 0), 1),
                            tint: colorScheme == .dark ? .white : .accentColor
                        )
                    }
                    sendButton
                }
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 8)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private var plusButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) {
                showUploadOptions.toggle()
            }
        } label: {
            ZStack {
                if showUploadOptions {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.08), in: Circle())
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showUploadOptions)
        }
        .buttonStyle(.plain)
    }

    private var composerWithPopover: some View {
        VStack(spacing: 0) {
            composer

            if showUploadOptions {
                UploadOptionsPanel(
                    onCamera: {
                        showUploadOptions = false
                        showCamera = true
                    },
                    onPhotoLibrary: {
                        showUploadOptions = false
                        showPhotoLibrary = true
                    },
                    onFiles: {
                        showUploadOptions = false
                        showDocumentPicker = true
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
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
        } else if let question = viewModel.pendingQuestion {
            QuestionComposerPanel(
                question: question,
                pendingCount: viewModel.pendingQuestions.count,
                isResponding: viewModel.respondingQuestionID == question.id,
                onAnswer: { answers in
                    Task { await viewModel.respond(to: question, answers: answers) }
                },
                onCancel: {
                    Task { await viewModel.cancelQuestion(question) }
                }
            )
        } else {
            composerWithPopover
        }
    }

    private var canSend: Bool {
        !viewModel.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !viewModel.composerAttachments.isEmpty
    }
}
