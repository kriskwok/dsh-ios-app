import SwiftUI
import Photos
import PhotosUI

// MARK: - Photo Library Picker

/// A bottom-anchored floating panel for multi-selecting photos from the library.
/// Features: 3-column square grid, infinite scroll, pull-to-dismiss when at top,
/// selected-count capsule at bottom, close + submit buttons at top.
struct PhotoLibraryPicker: View {
    let onSubmit: ([UIImage]) -> Void
    let onClose: () -> Void

    @StateObject private var loader = PhotoLibraryLoader()
    @State private var selectedIDs: Set<String> = []
    @State private var sheetOffset: CGFloat = 0
    @State private var isDraggingSheet = false
    @State private var scrollOffset: CGFloat = 0
    @State private var sheetHeight: CGFloat = 0

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        GeometryReader { geo in
            let totalHeight = geo.size.height
            let dismissThreshold = totalHeight * 0.6 // panel occupies < 2/5 => offset > 3/5

            ZStack(alignment: .bottom) {
                // Dimmed background
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onClose)

                // The panel
                VStack(spacing: 0) {
                    topBar
                    photoGrid
                    if !selectedIDs.isEmpty {
                        bottomCapsule
                    }
                }
                .frame(width: geo.size.width)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(uiColor: .systemBackground))
                        .ignoresSafeArea(edges: .bottom)
                )
                .offset(y: sheetOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            // Only allow sheet drag when scroll is at top and dragging down
                            if scrollOffset <= 0 && value.translation.height > 0 {
                                isDraggingSheet = true
                                sheetOffset = value.translation.height
                            }
                        }
                        .onEnded { value in
                            if isDraggingSheet {
                                if sheetOffset > dismissThreshold {
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        sheetOffset = totalHeight
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        onClose()
                                    }
                                } else {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        sheetOffset = 0
                                    }
                                }
                                isDraggingSheet = false
                            }
                        }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .onAppear { loader.requestAuthorizationAndLoad() }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                submitSelected()
            } label: {
                Text("提交")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(selectedIDs.isEmpty ? Color.secondary : Color.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(selectedIDs.isEmpty ? Color.primary.opacity(0.1) : Color.accentColor)
                    )
            }
            .buttonStyle(.plain)
            .disabled(selectedIDs.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.4)
        }
    }

    // MARK: - Photo Grid

    private var photoGrid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(loader.assets) { asset in
                    PhotoGridCell(
                        asset: asset,
                        isSelected: selectedIDs.contains(asset.id),
                        selectionIndex: selectionIndex(for: asset.id),
                        onTap: { toggle(asset) }
                    )
                    .onAppear {
                        if asset.id == loader.assets.last?.id {
                            loader.loadMore()
                        }
                    }
                }
            }
            .padding(2)
            .background(GeometryReader { proxy in
                Color.clear.preference(
                    key: ScrollOffsetKey.self,
                    value: proxy.frame(in: .named("photoScroll")).minY
                )
            })
        }
        .coordinateSpace(name: "photoScroll")
        .onPreferenceChange(ScrollOffsetKey.self) { value in
            scrollOffset = value
        }
        .scrollDisabled(isDraggingSheet)
    }

    // MARK: - Bottom Capsule

    private var bottomCapsule: some View {
        HStack {
            Spacer()
            Button {
                submitSelected()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 14))
                    Text("已选 \(selectedIDs.count) 张")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 11)
                .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    // MARK: - Helpers

    private func selectionIndex(for id: String) -> Int? {
        let sorted = Array(selectedIDs).sorted()
        return sorted.firstIndex(of: id).map { $0 + 1 }
    }

    private func toggle(_ asset: PhotoAsset) {
        if selectedIDs.contains(asset.id) {
            selectedIDs.remove(asset.id)
        } else {
            selectedIDs.insert(asset.id)
        }
    }

    private func submitSelected() {
        let selectedAssets = loader.assets.filter { selectedIDs.contains($0.id) }
        loader.requestImages(for: selectedAssets) { images in
            onSubmit(images)
        }
    }
}

// MARK: - Scroll Offset Preference

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Photo Grid Cell

private struct PhotoGridCell: View {
    let asset: PhotoAsset
    let isSelected: Bool
    let selectionIndex: Int?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            // Color.clear with aspectRatio(1) guarantees a square cell.
            // Image and selection UI are overlaid on top.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    ZStack(alignment: .topTrailing) {
                        if let thumbnail = asset.thumbnail {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Color(uiColor: .secondarySystemBackground)
                                .onAppear { asset.loadThumbnail() }
                        }

                        if isSelected {
                            Color.black.opacity(0.25)
                        }

                        selectionBadge
                            .padding(6)
                    }
                }
                .clipped()
        }
        .buttonStyle(.plain)
    }

    private var selectionBadge: some View {
        ZStack {
            if isSelected {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 22, height: 22)
                if let index = selectionIndex {
                    Text("\(index)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
            } else {
                Circle()
                    .stroke(.white, lineWidth: 2)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.black.opacity(0.2)))
            }
        }
    }
}

// MARK: - Photo Library Loader

@MainActor
final class PhotoLibraryLoader: ObservableObject {
    @Published var assets: [PhotoAsset] = []
    private var fetchResult: PHFetchResult<PHAsset>?
    private let imageManager = PHCachingImageManager()
    private let pageSize = 60
    private var loadedCount = 0
    private var isLoading = false

    func requestAuthorizationAndLoad() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            loadAssets()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] newStatus in
                if newStatus == .authorized || newStatus == .limited {
                    Task { @MainActor in self?.loadAssets() }
                }
            }
        default:
            break
        }
    }

    private func loadAssets() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        fetchResult = PHAsset.fetchAssets(with: options)
        loadMore()
    }

    func loadMore() {
        guard !isLoading, let fetchResult, loadedCount < fetchResult.count else { return }
        isLoading = true
        let end = min(loadedCount + pageSize, fetchResult.count)
        var newAssets: [PhotoAsset] = []
        for i in loadedCount..<end {
            let phAsset = fetchResult.object(at: i)
            let asset = PhotoAsset(phAsset: phAsset, imageManager: imageManager)
            newAssets.append(asset)
        }
        assets.append(contentsOf: newAssets)
        loadedCount = end
        isLoading = false
    }

    func requestImages(for photoAssets: [PhotoAsset], completion: @escaping ([UIImage]) -> Void) {
        guard !photoAssets.isEmpty else {
            completion([])
            return
        }
        let group = DispatchGroup()
        var images: [UIImage?] = Array(repeating: nil, count: photoAssets.count)

        for (index, asset) in photoAssets.enumerated() {
            group.enter()
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.resizeMode = .none

            imageManager.requestImage(
                for: asset.phAsset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .default,
                options: options
            ) { image, _ in
                images[index] = image
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(images.compactMap { $0 })
        }
    }
}

// MARK: - Photo Asset

@MainActor
final class PhotoAsset: Identifiable, ObservableObject {
    let id: String
    let phAsset: PHAsset
    let imageManager: PHCachingImageManager
    @Published var thumbnail: UIImage?

    init(phAsset: PHAsset, imageManager: PHCachingImageManager) {
        self.id = phAsset.localIdentifier
        self.phAsset = phAsset
        self.imageManager = imageManager
    }

    func loadThumbnail() {
        guard thumbnail == nil else { return }
        let size = CGSize(width: 200, height: 200)
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        imageManager.requestImage(
            for: phAsset,
            targetSize: size,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, _ in
            Task { @MainActor in
                self?.thumbnail = image
            }
        }
    }
}
