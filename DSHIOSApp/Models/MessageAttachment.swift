import Foundation
import UIKit
import UniformTypeIdentifiers

// MARK: - Attachment Types

enum AttachmentKind: String, Codable, Sendable {
    case image
    case file
}

/// Status of an attachment's lifecycle.
enum AttachmentStatus: String, Codable, Sendable {
    case preparing   // reading / compressing
    case ready       // local data ready, not yet uploaded
    case uploading   // uploading to server
    case uploaded    // server accepted, has remote URL
    case failed      // upload or prep failed
}

// MARK: - Composer Attachment (used while composing)

/// An attachment held in the composer before sending.
/// Carries the actual local payload (image or file URL) plus upload state.
@MainActor
final class ComposerAttachment: Identifiable, ObservableObject {
    let id: String
    let kind: AttachmentKind
    let name: String
    let size: Int64
    /// For images: the display image (may be compressed).
    let image: UIImage?
    /// For files: a local file URL the app can read.
    let fileURL: URL?
    /// MIME type if known.
    let mimeType: String?

    @Published var status: AttachmentStatus = .preparing
    @Published var progress: Double = 0       // 0...1
    @Published var errorMessage: String?
    /// Remote URL after successful upload (once backend protocol is defined).
    @Published var remoteURL: String?

    init(
        id: String = UUID().uuidString,
        kind: AttachmentKind,
        name: String,
        size: Int64,
        image: UIImage? = nil,
        fileURL: URL? = nil,
        mimeType: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.size = size
        self.image = image
        self.fileURL = fileURL
        self.mimeType = mimeType
    }

    /// A short descriptor used when embedding into the prompt text until the
    /// backend multimodal protocol is finalised.
    var descriptor: String {
        let sizeDesc = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        switch kind {
        case .image:
            return "[图片附件: \(name) (\(sizeDesc))]"
        case .file:
            return "[文件附件: \(name) (\(sizeDesc))]"
        }
    }
}

// MARK: - Message Attachment (persisted / rendered in a message)

/// A lightweight, Codable attachment snapshot stored on a ConversationMessage.
/// Does not carry raw image data — uses a local cache key, remote URL,
/// attachmentId (fetched via session.attachment), or base64 data.
struct MessageAttachment: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let kind: AttachmentKind
    let name: String
    let size: Int64
    let mimeType: String?
    /// Remote URL if uploaded.
    let url: String?
    /// For images: local cache file name (relative to caches/attachments).
    let localImageName: String?
    /// DSH attachment ID (sha256:...), fetched via session.attachment API.
    let attachmentId: String?
    /// Inline base64-encoded image data (from content blocks that embed data).
    let base64Data: String?
    /// Hermes-style server-side file path (e.g. /root/.hermes-web-ui/upload/default/xxx.png).
    /// Fetched via the Hermes agent's file-serving endpoint.
    let remotePath: String?

    init(
        id: String,
        kind: AttachmentKind,
        name: String,
        size: Int64,
        mimeType: String? = nil,
        url: String? = nil,
        localImageName: String? = nil,
        attachmentId: String? = nil,
        base64Data: String? = nil,
        remotePath: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.size = size
        self.mimeType = mimeType
        self.url = url
        self.localImageName = localImageName
        self.attachmentId = attachmentId
        self.base64Data = base64Data
        self.remotePath = remotePath
    }
}

// MARK: - Attachment Cache

/// Persists image attachments to disk so message rows can reload thumbnails.
enum AttachmentCache {
    private static let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("message_attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func saveImage(_ image: UIImage, id: String) -> String? {
        let name = "\(id).jpg"
        let url = directory.appendingPathComponent(name)
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    /// Save raw image data (PNG/JPEG/etc) to cache, returns the file name.
    static func saveImageData(_ data: Data, id: String, ext: String = "img") -> String? {
        let name = "\(id).\(ext)"
        let url = directory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    static func loadImage(name: String) -> UIImage? {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    static func fileURL(for name: String) -> URL {
        directory.appendingPathComponent(name)
    }
}

// MARK: - Helpers

enum AttachmentHelper {
    static func mimeType(for url: URL) -> String? {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return nil
    }

    static func isImageExtension(_ ext: String) -> Bool {
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }
}
