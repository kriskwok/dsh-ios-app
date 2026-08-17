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
                    guard focused, isFollowingLatest else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(220))
                        guard composerFocused else { return }
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
            Text(workspaceTitle.map { "将在“\($0)”工作区开始" } ?? "消息会直接发送给远程服务器上的 \(viewModel.agentName)。")
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

private struct ApprovalComposerPanel: View {
    let approval: AgentApprovalRequest
    let pendingCount: Int
    let isResponding: Bool
    let onChoice: (AgentApprovalChoice) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                    Text("等待审批")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    if pendingCount > 1 {
                        Text("还有 \(pendingCount - 1) 项")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isResponding { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.10))

                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(approval.description)
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(approval.toolName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let command = approval.command, !command.isEmpty {
                            Text(command)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color.primary.opacity(0.045))
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        if approval.isSmartDenied {
                            Label("该操作已被安全策略拦截，只能临时放行一次。", systemImage: "shield.lefthalf.filled")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 15)
                    .padding(.top, 12)
                }
                .frame(maxHeight: 170)

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(approval.choices, id: \.self) { choice in
                        choiceButton(choice)
                    }
                }
                .padding(14)
            }
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.orange.opacity(0.55), lineWidth: 1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        .background(Color(uiColor: .systemBackground))
    }

    @ViewBuilder
    private func choiceButton(_ choice: AgentApprovalChoice) -> some View {
        switch choice {
        case .once:
            Button(choice.title) { onChoice(choice) }
                .buttonStyle(.borderedProminent)
                .disabled(isResponding)
        case .session:
            Button(choice.title) { onChoice(choice) }
                .buttonStyle(.bordered)
                .disabled(isResponding)
        case .always:
            Button(choice.title) { onChoice(choice) }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(isResponding)
        case .deny:
            Button(choice.title) { onChoice(choice) }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isResponding)
        }
    }
}

private struct MessageRow: View {
    let message: ConversationMessage
    let onDSHUIAction: (String, [String: JSONValue]) -> Void
    @State private var isReasoningExpanded = false

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                MarkdownText(message.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .opacity(message.isPending ? 0.65 : 1)
            }

        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                if !message.reasoning.isEmpty {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            isReasoningExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("思考过程")
                                .font(.subheadline.weight(.medium))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .rotationEffect(.degrees(isReasoningExpanded ? 90 : 0))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("思考过程")
                    .accessibilityValue(isReasoningExpanded ? "已展开" : "已收起")

                    if isReasoningExpanded {
                        MarkdownText(message.reasoning)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(11)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                if !message.text.isEmpty {
                    DSHUIRichText(message.text, onAction: onDSHUIAction)
                }
                if message.isStreaming {
                    StreamingCursor()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .activity:
            HStack(spacing: 7) {
                if message.isStreaming {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "checkmark.circle")
                }
                Text(message.text)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MarkdownText: View {
    let value: AttributedString
    let blocks: [MarkdownBlock]

    init(_ text: String) {
        let normalizedText = MarkdownBlockParser.normalize(text)
        value = (try? AttributedString(
            markdown: text,
            options: .init(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(text)
        blocks = MarkdownBlockParser.blocks(in: normalizedText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .textSelection(.enabled)
    }
}

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case unorderedList([String])
    case orderedList([String])
    case quote(String)
    case code(language: String?, text: String)
    case table(headers: [String], rows: [[String]])
    case divider
}

enum MarkdownBlockParser {
    static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
    }

    static func blocks(in text: String) -> [MarkdownBlock] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }

            if isFenceStart(line) {
                let language = fenceLanguage(in: line)
                index += 1
                var code: [String] = []
                while index < lines.count, !isFenceEnd(lines[index]) {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(language: language, text: code.joined(separator: "\n")))
                continue
            }

            if let heading = parseHeading(trimmed) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isDivider(trimmed) {
                blocks.append(.divider)
                index += 1
                continue
            }

            if index + 1 < lines.count,
               let headers = tableRow(lines[index]),
               isTableDelimiter(lines[index + 1]) {
                index += 2
                var rows: [[String]] = []
                while index < lines.count, let row = tableRow(lines[index]), !row.isEmpty {
                    rows.append(row)
                    index += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            if let item = unorderedItem(trimmed) {
                var items = [item]
                index += 1
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let item = unorderedItem(next) else { break }
                    items.append(item)
                    index += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            if let item = orderedItem(trimmed) {
                var items = [item.text]
                index += 1
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let item = orderedItem(next) else { break }
                    items.append(item.text)
                    index += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            if let quote = quoteLine(trimmed) {
                var linesInQuote = [quote]
                index += 1
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let quote = quoteLine(next) else { break }
                    linesInQuote.append(quote)
                    index += 1
                }
                blocks.append(.quote(linesInQuote.joined(separator: "\n")))
                continue
            }

            var paragraph = [line]
            index += 1
            while index < lines.count {
                let next = lines[index]
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty || startsBlock(nextTrimmed, nextLine: index + 1 < lines.count ? lines[index + 1] : nil) {
                    break
                }
                paragraph.append(next)
                index += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        }

        return blocks
    }

    private static func startsBlock(_ line: String, nextLine: String?) -> Bool {
        isFenceStart(line)
            || parseHeading(line) != nil
            || isDivider(line)
            || unorderedItem(line) != nil
            || orderedItem(line) != nil
            || quoteLine(line) != nil
            || (nextLine.map(isTableDelimiter) ?? false && tableRow(line) != nil)
    }

    private static func isFenceStart(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    private static func fenceLanguage(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") else { return nil }
        let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        return language.isEmpty ? nil : language
    }

    private static func isFenceEnd(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for character in line {
            guard character == "#" else { break }
            level += 1
        }
        guard (1...6).contains(level) else { return nil }
        let remainder = line.dropFirst(level)
        guard remainder.first == " " || remainder.first == "\t" else { return nil }
        let text = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (level, text)
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        return compact == "---" || compact == "***" || compact == "___"
    }

    private static func unorderedItem(_ line: String) -> String? {
        guard let marker = line.first, "-*+".contains(marker) else { return nil }
        let remainder = line.dropFirst()
        guard remainder.first == " " || remainder.first == "\t" else { return nil }
        let item = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        return item.isEmpty ? nil : item
    }

    private static func orderedItem(_ line: String) -> (number: Int, text: String)? {
        var digits = ""
        var remainder = line[...]
        while let first = remainder.first, first.isNumber {
            digits.append(first)
            remainder = remainder.dropFirst()
        }
        guard !digits.isEmpty, remainder.first == "." || remainder.first == ")" else { return nil }
        remainder = remainder.dropFirst()
        guard remainder.first == " " || remainder.first == "\t",
              let number = Int(digits) else { return nil }
        return (number, remainder.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func quoteLine(_ line: String) -> String? {
        guard line.first == ">" else { return nil }
        return String(line.dropFirst().trimmingCharacters(in: .whitespaces))
    }

    private static func tableRow(_ line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.first == "|" { value.removeFirst() }
        if value.last == "|" { value.removeLast() }
        let cells = value.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return cells.isEmpty ? nil : cells
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        guard let cells = tableRow(line), cells.count >= 1 else { return false }
        return cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: .whitespaces)
            guard value.count >= 3 else { return false }
            let withoutAlignment = value.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return withoutAlignment.allSatisfy { $0 == "-" }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            inlineText(text)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(level))
                .fixedSize(horizontal: false, vertical: true)
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(marker: "•", text: item)
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    listRow(marker: "\(index + 1).", text: item)
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: 3)
                inlineText(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 5) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .table(let headers, let rows):
            MarkdownTableView(headers: headers, rows: rows)
        case .divider:
            Divider()
        }
    }

    private func inlineText(_ text: String) -> some View {
        let value = (try? AttributedString(
            markdown: text,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(text)
        return Text(value)
            .font(.body)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .lineSpacing(3)
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(marker)
                .font(.body.weight(.semibold))
                .frame(minWidth: marker.count == 1 ? 10 : 22, alignment: .trailing)
            inlineText(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.bold)
        case 2: .title3.weight(.bold)
        case 3: .headline
        default: .subheadline.weight(.semibold)
        }
    }
}

private struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    private let columnWidth: CGFloat = 128

    var body: some View {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        ScrollView(.horizontal, showsIndicators: false) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(columnWidth), spacing: 0), count: max(1, columnCount)),
                spacing: 0
            ) {
                ForEach(0..<(max(1, columnCount) * (rows.count + 1)), id: \.self) { index in
                    let row = index / max(1, columnCount)
                    let column = index % max(1, columnCount)
                    let cells = row == 0 ? headers : rows[row - 1]
                    let text = column < cells.count ? cells[column] : ""
                    Text(markdownTableValue(text))
                        .font(row == 0 ? .subheadline.weight(.semibold) : .subheadline)
                        .multilineTextAlignment(.leading)
                        .frame(width: columnWidth, alignment: .leading)
                        .padding(8)
                        .background(row == 0 ? Color.primary.opacity(0.08) : Color.clear)
                        .overlay {
                            Rectangle().stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                        }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func markdownTableValue(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(text)
    }
}

private struct ThinkingIndicator: View {
    let agentName: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("\(agentName) 正在思考…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StreamingCursor: View {
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(width: 2, height: 16)
            .opacity(visible ? 1 : 0.2)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    visible.toggle()
                }
            }
    }
}

private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message).font(.caption).lineLimit(2)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}
