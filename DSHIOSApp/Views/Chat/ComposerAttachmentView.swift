import SwiftUI

// MARK: - Composer Attachment Strip

/// Horizontal strip of selected attachment thumbnails shown above the text field.
struct ComposerAttachmentStrip: View {
    @ObservedObject var viewModel: ChatSessionViewModel

    var body: some View {
        if !viewModel.composerAttachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.composerAttachments) { attachment in
                        ComposerAttachmentCard(attachment: attachment) {
                            viewModel.removeComposerAttachment(id: attachment.id)
                        }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            .frame(height: 72)
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }
}

// MARK: - Single Attachment Card

private struct ComposerAttachmentCard: View {
    @ObservedObject var attachment: ComposerAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                }

            // Remove button
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .background(Color.black.opacity(0.5), in: Circle())
                    .padding(2)
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
        }
        .padding(4)
    }

    @ViewBuilder
    private var content: some View {
        switch attachment.kind {
        case .image:
            if let image = attachment.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder(systemName: "photo")
            }
        case .file:
            fileCard
        }

        // Upload progress overlay
        if attachment.status == .preparing || attachment.status == .uploading {
            progressOverlay
        }
        if attachment.status == .failed {
            failedOverlay
        }
    }

    private var fileCard: some View {
        VStack(spacing: 4) {
            Image(systemName: fileIcon)
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            Text(attachment.name)
                .font(.system(size: 9))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var fileIcon: String {
        let ext = (attachment.name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "doc", "docx": return "doc.text"
        case "xls", "xlsx", "csv": return "tablecells"
        case "ppt", "pptx": return "slide"
        case "zip", "rar", "7z": return "doc.zipper"
        case "txt", "md": return "doc.plaintext"
        default: return "doc"
        }
    }

    private func placeholder(systemName: String) -> some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            Image(systemName: systemName)
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
        }
    }

    private var progressOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
            VStack(spacing: 4) {
                ProgressView(value: attachment.progress)
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(0.7)
                Text("\(Int(attachment.progress * 100))%")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
    }

    private var failedOverlay: some View {
        ZStack {
            Color.black.opacity(0.5)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.orange)
        }
    }
}
