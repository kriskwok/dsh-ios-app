import SwiftUI

// MARK: - Upload Options Panel

/// The expandable panel shown below the composer with 3 option cards:
/// 拍照 / 相册 / 文件.
struct UploadOptionsPanel: View {
    let onCamera: () -> Void
    let onPhotoLibrary: () -> Void
    let onFiles: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            optionCard(
                title: "拍照",
                systemImage: "camera.fill",
                tint: .blue,
                action: onCamera
            )
            optionCard(
                title: "相册",
                systemImage: "photo.on.rectangle",
                tint: .green,
                action: onPhotoLibrary
            )
            optionCard(
                title: "文件",
                systemImage: "folder.fill",
                tint: .orange,
                action: onFiles
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func optionCard(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(tint.opacity(0.12))
                        .frame(width: 48, height: 48)
                    Image(systemName: systemImage)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(tint)
                }
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground).opacity(0.6))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
    }
}
