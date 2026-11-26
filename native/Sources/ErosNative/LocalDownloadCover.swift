import SwiftUI
import ImageIO
import ErosCore
import ErosServices

struct LocalDownloadCoverKey: Hashable {
    let scope: SessionScope
    let storageID: UUID?
    let jobID: UUID
    let skippedPages: Int

    init(item: DownloadLibraryItem, coordinator: DownloadCoordinator, scope: SessionScope) {
        self.scope = scope
        storageID = coordinator.storageLease?.id
        jobID = item.jobID
        skippedPages = item.skippedPages.value
    }
}

struct LocalDownloadCover: View {
    let item: DownloadLibraryItem
    let coordinator: DownloadCoordinator
    let scope: SessionScope
    private let key: LocalDownloadCoverKey
    private let bitmap: PreviewRenderMemory<LocalDownloadCoverKey, UIImage>.Entry

    init(item: DownloadLibraryItem, coordinator: DownloadCoordinator, scope: SessionScope) {
        self.item = item
        self.coordinator = coordinator
        self.scope = scope
        key = LocalDownloadCoverKey(item: item, coordinator: coordinator, scope: scope)
        bitmap = PreviewBitmaps.shared.downloadCovers.entry(for: key)
    }

    private struct Request: Hashable {
        let key: LocalDownloadCoverKey
        let hasPages: Bool
        let completed: Bool
    }

    var body: some View {
        let hasPages = item.completedPages.value > 0
        Group {
            if hasPages, let image = bitmap.value {
                Image(uiImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: Request(key: key, hasPages: hasPages, completed: item.state == .completed)) {
            await load(hasPages: hasPages)
        }
    }

    private func load(hasPages: Bool) async {
        guard !Task.isCancelled else { return }
        let cache = PreviewBitmaps.shared.downloadCovers
        guard hasPages else {
            cache.remove(key)
            return
        }
        if bitmap.value != nil {
            cache.touch(key)
            return
        }

        do {
            guard let file = try await coordinator.localCoverFile(id: item.jobID, galleryID: item.summary.reference.key.galleryID, scope: scope),
                  bitmap.value == nil,
                  let decoded = try await DownloadCoverDecoder.shared.thumbnail(file) else { return }
            try Task.checkCancellation()
            try coordinator.storageLease?.check()
            if bitmap.value == nil {
                cache.insert(UIImage(cgImage: decoded), for: key, cost: decoded.bytesPerRow * decoded.height)
            }
        } catch {
            // The cover is optional. Leave the placeholder until a later list read.
        }
    }
}

private actor DownloadCoverDecoder {
    static let shared = DownloadCoverDecoder()

    func thumbnail(_ file: URL) throws -> CGImage? {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}
