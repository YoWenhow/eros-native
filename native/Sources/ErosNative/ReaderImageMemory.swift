import UIKit
import Observation
import ErosCore
import ErosServices

/// One reader/document lifetime. Never shared across galleries, accounts or sites.
@MainActor @Observable final class ReaderImageMemory {
    struct Key: Hashable { let index: Int; let continuous: Bool }
    private struct Entry {
        let image: UIImage
        let displayedLoader: ReaderViewModel?
        let digest: String?
    }
    @ObservationIgnored private var cache = ReaderMemoryCache<Key, Entry>(maximumCost: 96 * 1024 * 1024, maximumCount: 12)
    private var displayRevision = 0
    private(set) var blockedThumbnailPages: Set<Int> = []
    let prefetch = ReaderPrefetchSession()
    private var revealedDigests: Set<String> = []
    func resetReveals() { revealedDigests.removeAll() }
    func reveal(_ digest: String) {
        revealedDigests.insert(digest)
        displayRevision &+= 1
    }
    func isBlocked(_ loader: ReaderViewModel) -> Bool {
        guard let entry = loader.blockedImage else { return false }
        return !revealedDigests.contains(entry.digest)
    }
    private(set) var aspectRatios: [Int: Double] = [:]
    private func cached(_ index: Int, continuous: Bool) -> Entry? {
        cache.value(for: Key(index: index, continuous: continuous))
    }

    func displayedLoader(at index: Int, continuous: Bool) -> ReaderViewModel? {
        cached(index, continuous: continuous)?.displayedLoader
    }

    func displayedImage(at index: Int, continuous: Bool) -> UIImage? {
        _ = displayRevision
        guard let entry = cached(index, continuous: continuous), let loader = entry.displayedLoader,
              !isBlocked(loader) else { return nil }
        return entry.image
    }

    func restoreCached(_ page: PageIndex, using loader: ReaderViewModel, waitForOfflinePrefetch: Bool) async -> UIImage? {
        if waitForOfflinePrefetch && loader.isOffline { await prefetch.waitForPrefetch(of: page) }
        guard !Task.isCancelled, let entry = cached(page.value, continuous: false) else { return nil }
        return await loader.restoreDecoded(index: page, digest: entry.digest) ? entry.image : nil
    }

    func load(_ page: PageIndex, using loader: ReaderViewModel, continuous: Bool, retry: Bool = false) async -> UIImage? {
        if retry {
            if loader.isOffline { prefetch.cancelPrefetch(of: page) }
            remove(page.value, continuous: continuous)
        } else {
            if loader.isOffline { await prefetch.waitForPrefetch(of: page) }
            guard !Task.isCancelled else { return nil }
            if let cached = cached(page.value, continuous: continuous) {
                return await loader.restoreDecoded(index: page, digest: cached.digest) ? cached.image : nil
            }
        }
        return await loader.loadDecoded(index: page, retry: retry) { data in
            try await ReaderImageDecoder.decode(data, continuous: continuous)
        }
    }

    func predecodeOffline(_ page: PageIndex, using reader: ReaderViewModel, continuous: Bool) async -> Bool {
        if cached(page.value, continuous: continuous) != nil { return true }
        let loader = reader.pageModel(index: page)
        let image = await loader.loadDecoded(index: page) { data in
            try await ReaderImageDecoder.decode(data, continuous: continuous)
        }
        loader.releaseCompressedBytes()
        guard !Task.isCancelled, UIApplication.shared.applicationState == .active,
              !PrivacyController.shared.locked, !PrivacyController.shared.busy else { return false }
        guard let image else {
            // A hole in a partial download should not stop warming later pages.
            return loader.error == .notFound || loader.error == .unsupportedContent
        }
        // With a long look-ahead, avoid evicting the next turn's bitmaps to fit
        // farther pages. The nearest two also cover a full horizontal spread.
        let nearby = page.value <= (prefetch.visiblePages.max() ?? -1) + 2
        return insert(image, loader: loader, index: page.value, continuous: continuous,
            displayed: false, onlyIfSpace: !nearby)
    }

    @discardableResult
    func insert(_ image: UIImage, loader: ReaderViewModel, index: Int, continuous: Bool,
                displayed: Bool = true, onlyIfSpace: Bool = false) -> Bool {
        guard let bitmap = image.cgImage else { return false }
        let cost = bitmap.bytesPerRow * bitmap.height
        guard cost <= cache.maximumCost else { return false }
        if onlyIfSpace, cache.count == cache.maximumCount || cost > cache.maximumCost - cache.cost { return false }
        aspectRatios[index] = image.size.height / max(1, image.size.width)
        let entry = Entry(image: image, displayedLoader: displayed ? loader : nil, digest: loader.contentDigest)
        cache.insert(entry, for: Key(index: index, continuous: continuous), cost: cost)
        if loader.blockedImage != nil { blockedThumbnailPages.insert(index) }
        else if blockedThumbnailPages.contains(index) { blockedThumbnailPages.remove(index) }
        displayRevision &+= 1
        return true
    }
    func remove(_ index: Int, continuous: Bool) {
        cache.remove(Key(index: index, continuous: continuous))
        displayRevision &+= 1
    }
    func trim(keeping pages: Set<Int>, continuous: Bool) {
        cache.retain { $0.continuous == continuous && pages.contains($0.index) }
        displayRevision &+= 1
    }
    func clear() {
        cache.clear()
        displayRevision &+= 1
    }
}
