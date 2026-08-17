import SwiftUI

struct MessageRow: View {
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
