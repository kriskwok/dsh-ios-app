import SwiftUI

struct QuestionComposerPanel: View {
    let question: AgentQuestionRequest
    let pendingCount: Int
    let isResponding: Bool
    let onAnswer: ([AgentQuestionAnswer]) -> Void
    let onCancel: () -> Void

    @State private var currentIndex = 0
    @State private var selected: [[String]] = []
    @State private var customTexts: [String] = []
    @State private var isMinimized = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if !isMinimized {
                content
                footer
            }
        }
        .background(Color(uiColor: .systemBackground))
        .onAppear { seedDraftsIfNeeded() }
    }

    private var current: AgentQuestion {
        question.questions[min(currentIndex, question.questions.count - 1)]
    }

    private var currentSelected: Binding<[String]> {
        Binding(
            get: { selected.indices.contains(currentIndex) ? selected[currentIndex] : [] },
            set: { newValue in
                while selected.count <= currentIndex { selected.append([]) }
                selected[currentIndex] = newValue
            }
        )
    }

    private var currentCustom: Binding<String> {
        Binding(
            get: { customTexts.indices.contains(currentIndex) ? customTexts[currentIndex] : "" },
            set: { newValue in
                while customTexts.count <= currentIndex { customTexts.append("") }
                customTexts[currentIndex] = newValue
            }
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
            Text("等待回答")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            if pendingCount > 1 {
                Text("还有 \(pendingCount - 1) 项")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isResponding { ProgressView().controlSize(.small) }
            Button {
                withAnimation(.snappy(duration: 0.2)) { isMinimized.toggle() }
            } label: {
                Image(systemName: isMinimized ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isResponding)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isResponding)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.10))
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let header = current.header, !header.isEmpty {
                    Text(header)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(current.question)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let detail = current.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !current.options.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(Array(current.options.enumerated()), id: \.element.id) { index, option in
                            optionButton(option, index: index)
                        }
                    }
                }
                customInput
            }
            .padding(.horizontal, 15)
            .padding(.top, 12)
        }
        .frame(maxHeight: 220)
    }

    private func optionButton(_ option: AgentQuestionOption, index: Int) -> some View {
        let isSelected = currentSelected.wrappedValue.contains(option.label)
        return Button {
            toggle(option.label)
        } label: {
            HStack(spacing: 10) {
                if current.multiSelect {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 16))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                } else {
                    Text("\(index + 1)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelected ? .white : Color.accentColor)
                        .frame(width: 22, height: 22)
                        .background(isSelected ? Color.accentColor : Color.accentColor.opacity(0.12), in: Circle())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(isResponding)
    }

    private var customInput: some View {
        TextField(current.options.isEmpty ? "输入回答…" : "其他（可选）…", text: currentCustom, axis: .vertical)
            .lineLimit(1...3)
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .disabled(isResponding)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if question.questions.count > 1 {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        currentIndex = max(0, currentIndex - 1)
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(Color.primary.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(currentIndex == 0 || isResponding)
            }
            Spacer()
            if question.questions.count > 1 {
                Text("\(currentIndex + 1) / \(question.questions.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button("跳过") {
                skipCurrent()
            }
            .font(.subheadline)
            .buttonStyle(.bordered)
            .disabled(isResponding)
            Button(currentIndex == question.questions.count - 1 ? "提交" : "下一步") {
                advance()
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .disabled(isResponding || !currentAnswered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var currentAnswered: Bool {
        !currentSelected.wrappedValue.isEmpty || !currentCustom.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func toggle(_ label: String) {
        var value = currentSelected.wrappedValue
        if current.multiSelect {
            if let index = value.firstIndex(of: label) {
                value.remove(at: index)
            } else {
                value.append(label)
            }
        } else {
            value = [label]
        }
        currentSelected.wrappedValue = value
        if !current.multiSelect && currentIndex < question.questions.count - 1 {
            withAnimation(.snappy(duration: 0.2)) { currentIndex += 1 }
        }
    }

    private func skipCurrent() {
        if currentIndex < question.questions.count - 1 {
            withAnimation(.snappy(duration: 0.2)) { currentIndex += 1 }
        } else {
            submit()
        }
    }

    private func advance() {
        if currentIndex < question.questions.count - 1 {
            withAnimation(.snappy(duration: 0.2)) { currentIndex += 1 }
        } else {
            submit()
        }
    }

    private func submit() {
        let answers = question.questions.enumerated().map { index, item -> AgentQuestionAnswer in
            let picked = selected.indices.contains(index) ? selected[index] : []
            let custom = customTexts.indices.contains(index) ? customTexts[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let effective = item.multiSelect ? picked : (custom.isEmpty ? picked : [])
            return AgentQuestionAnswer(
                id: item.id,
                selected: effective,
                custom: custom.isEmpty || item.multiSelect ? nil : custom
            )
        }
        onAnswer(answers)
    }

    private func seedDraftsIfNeeded() {
        guard selected.isEmpty else { return }
        selected = question.questions.map { _ in [] }
        customTexts = question.questions.map { _ in "" }
    }
}
