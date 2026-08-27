import SwiftUI

// MARK: - Message Attachment View

/// Renders attachments (images / files) inside a message bubble.
/// `attachmentLoader` is used to fetch binary data for attachments referenced
/// by `attachmentId` (DSH session.attachment API).
struct MessageAttachmentView: View {
    let attachments: [MessageAttachment]
    var attachmentLoader: ((String, String, String) async -> Data?)? = nil
    /// Fetches file data by server-side path (used for Hermes remotePath attachments).
    var remoteFileLoader: ((String) async -> Data?)? = nil

    /// Max width for image content — ~68% of screen, capped for large screens.
    private var maxImageWidth: CGFloat {
        min(UIScreen.main.bounds.width * 0.68, 300)
    }

    var body: some View {
        if !attachments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                let images = attachments.filter { $0.kind == .image }
                if !images.isEmpty {
                    imageContent(images)
                }

                let files = attachments.filter { $0.kind == .file }
                if !files.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(files) { file in
                            fileCard(file)
                        }
                    }
                    .frame(maxWidth: maxImageWidth, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Image Content

    @ViewBuilder
    private func imageContent(_ images: [MessageAttachment]) -> some View {
        if images.count == 1, let first = images.first {
            // Single image: preserve aspect ratio, cap width.
            MessageImageCell(
                attachment: first,
                attachmentLoader: attachmentLoader,
                remoteFileLoader: remoteFileLoader,
                contentMode: .fit
            )
            .frame(maxWidth: maxImageWidth)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            // Multiple images: square thumbnail grid.
            let columns = images.count == 2 ? 2 : 3
            let gridItems = Array(repeating: GridItem(.flexible(), spacing: 4), count: columns)
            LazyVGrid(columns: gridItems, spacing: 4) {
                ForEach(images) { attachment in
                    MessageImageCell(
                        attachment: attachment,
                        attachmentLoader: attachmentLoader,
                        remoteFileLoader: remoteFileLoader,
                        contentMode: .fill
                    )
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .frame(maxWidth: maxImageWidth)
        }
    }

    // MARK: - File Card

    private func fileCard(_ file: MessageAttachment) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: fileIcon(for: file.name))
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if let url = file.url, let link = URL(string: url) {
                Link(destination: link) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "doc", "docx": return "doc.text"
        case "xls", "xlsx", "csv": return "tablecells"
        case "ppt", "pptx": return "slide"
        case "zip", "rar", "7z": return "doc.zipper"
        case "txt", "md": return "doc.plaintext"
        case "jpg", "jpeg", "png", "gif", "heic": return "photo"
        default: return "doc"
        }
    }
}

// MARK: - Message Image Cell

private struct MessageImageCell: View {
    let attachment: MessageAttachment
    let attachmentLoader: ((String, String, String) async -> Data?)?
    let remoteFileLoader: ((String) async -> Data?)?
    let contentMode: ContentMode
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var showFullScreen = false

    var body: some View {
        Button {
            if image != nil {
                showFullScreen = true
            } else if loadFailed {
                retry()
            }
        } label: {
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else if isLoading {
                    loadingView
                        .frame(width: contentMode == .fit ? 240 : nil,
                               height: contentMode == .fit ? 240 : nil)
                } else if loadFailed {
                    failedView
                        .frame(width: contentMode == .fit ? 240 : nil,
                               height: contentMode == .fit ? 240 : nil)
                } else if let url = attachment.url, let remoteURL = URL(string: url) {
                    AsyncImage(url: remoteURL) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().aspectRatio(contentMode: contentMode)
                        case .failure:
                            placeholder
                        default:
                            ProgressView().tint(.white)
                        }
                    }
                    .frame(width: contentMode == .fit ? 240 : nil,
                           height: contentMode == .fit ? 240 : nil)
                } else {
                    placeholder
                        .frame(width: contentMode == .fit ? 240 : nil,
                               height: contentMode == .fit ? 240 : nil)
                        .onAppear { loadImage() }
                }
            }
            // Thumbnail mode expands to fill the grid cell; fit mode sizes to content.
            .frame(maxWidth: contentMode == .fill ? .infinity : nil,
                   maxHeight: contentMode == .fill ? .infinity : nil)
            .clipped()
        }
        .buttonStyle(.plain)
        .onAppear { if image == nil && !isLoading && !loadFailed { loadImage() } }
        .fullScreenCover(isPresented: $showFullScreen) {
            if let image {
                FullScreenImageViewer(image: image)
            }
        }
    }

    private var loadingView: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            VStack(spacing: 6) {
                ProgressView()
                    .tint(.secondary)
                Text("加载中…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var failedView: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.system(size: 18))
                    .foregroundStyle(.orange)
                Text("点击重试")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            Image(systemName: "photo")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
        }
    }

    private func retry() {
        loadFailed = false
        image = nil
        loadImage()
    }

    private func loadImage() {
        print("[ImageCell] load id=\(attachment.id) name=\(attachment.name) localImageName=\(attachment.localImageName ?? "nil") base64=\(attachment.base64Data != nil) attachmentId=\(attachment.attachmentId ?? "nil") remotePath=\(attachment.remotePath ?? "nil") hasLoader=\(attachmentLoader != nil) hasRemoteLoader=\(remoteFileLoader != nil)")

        // 1. Local cache (from composer-sent images)
        if let name = attachment.localImageName {
            image = AttachmentCache.loadImage(name: name)
            if image != nil {
                print("[ImageCell] loaded from local cache: \(name)")
                return
            }
            print("[ImageCell] local cache miss: \(name)")
        }

        // 2. Inline base64 data
        if let base64 = attachment.base64Data,
           let data = Data(base64Encoded: base64),
           let img = UIImage(data: data) {
            image = img
            return
        }

        // 3. Fetch via attachmentId (DSH session.attachment API)
        if let attachmentId = attachment.attachmentId, let loader = attachmentLoader {
            isLoading = true
            loadFailed = false
            let ext = (attachment.name as NSString).pathExtension.isEmpty ? "img" : (attachment.name as NSString).pathExtension
            Task {
                if let data = await loader(attachmentId, attachment.id, ext),
                   let img = UIImage(data: data) {
                    await MainActor.run {
                        image = img
                        isLoading = false
                    }
                } else {
                    await MainActor.run {
                        isLoading = false
                        loadFailed = true
                    }
                }
            }
            return
        }

        // 4. Fetch via remotePath (Hermes Studio server-side file path)
        if let remotePath = attachment.remotePath, let loader = remoteFileLoader {
            isLoading = true
            loadFailed = false
            print("[ImageCell] fetching remotePath: \(remotePath)")
            Task {
                if let data = await loader(remotePath),
                   let img = UIImage(data: data) {
                    print("[ImageCell] remotePath loaded: \(remotePath) size=\(data.count)")
                    await MainActor.run {
                        image = img
                        isLoading = false
                    }
                } else {
                    print("[ImageCell] remotePath load failed: \(remotePath)")
                    await MainActor.run {
                        isLoading = false
                        loadFailed = true
                    }
                }
            }
            return
        }

        print("[ImageCell] no loading path available")
        loadFailed = true
    }
}

// MARK: - Full Screen Image Viewer

private struct FullScreenImageViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .padding()

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
            }
        }
    }
}
