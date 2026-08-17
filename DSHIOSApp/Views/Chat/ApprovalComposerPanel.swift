import SwiftUI

struct ApprovalComposerPanel: View {
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
