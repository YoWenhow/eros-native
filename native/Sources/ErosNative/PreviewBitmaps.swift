import UIKit
import ImageIO
import ErosCore
import ErosServices

struct PreviewBitmapKey: Hashable {
    let url: URL?
    let scope: SessionScope
    let width: Int?
    let height: Int?
    let offset: Int
    let imagePageURL: URL?
    init(url: URL?, scope: SessionScope, size: PixelSize?, offset: NonnegativeCount?, imagePageURL: URL?) {
        self.url = url; self.scope = scope; self.imagePageURL = imagePageURL
        width = size?.width; height = size?.height; self.offset = offset?.value ?? 0
    }
}

@MainActor final class PreviewBitmaps {
    static let shared = PreviewBitmaps()
    let memory = PreviewRenderMemory<PreviewBitmapKey, UIImage>(maximumCost: 24 * 1024 * 1024, maximumCount: 160)
    let downloadCovers = PreviewRenderMemory<LocalDownloadCoverKey, UIImage>(maximumCost: 16 * 1024 * 1024, maximumCount: 96)
    private var observer: NSObjectProtocol?
    private init() {
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.memory.clear()
                self?.downloadCovers.clear()
                await PreviewRasterDecoder.shared.clear()
            }
        }
    }
}

/// A serial background actor. Rasterize cropped sprites here, rather than leaving
/// compressed CGImages for the main-thread render commit to decompress.
actor PreviewRasterDecoder {
    static let shared = PreviewRasterDecoder()
    private struct SourceKey: Hashable { let url: URL; let scope: SessionScope }
    private var sprites = ReaderMemoryCache<SourceKey, CGImage>(maximumCost: 16 * 1024 * 1024, maximumCount: 3)
    func clear() { sprites.clear() }
    func image(for key: PreviewBitmapKey, loader: PreviewImageLoader) async throws -> CGImage {
        guard let url = key.url else { throw AppError.invalidInput }
        try await loader.validate(scope: key.scope)
        let disk = await loader.diskCache
        let diskKey = PreviewRasterKey(url: url, storage: key.scope.storage, width: key.width, height: key.height, offset: key.offset, imagePageURL: key.imagePageURL)
        let ticket = try? await disk?.writeTicket(scope: key.scope)
        if let stored = try? await disk?.read(diskKey, scope: key.scope), let restored = restore(stored) {
            try Task.checkCancellation(); return restored
        }
        let sourceKey = SourceKey(url: url, scope: key.scope)
        if let width = key.width, let height = key.height, let sprite = sprites.value(for: sourceKey) {
            let result = try crop(sprite, width: width, height: height, offset: key.offset)
            await persist(result, disk: disk, key: diskKey, scope: key.scope, ticket: ticket)
            return result
        }
        let data = try await loader.load(url: url, scope: key.scope)
        try Task.checkCancellation()
        // Other crops of this same sprite may have completed while awaiting IO.
        if let width = key.width, let height = key.height, let sprite = sprites.value(for: sourceKey) {
            let result = try crop(sprite, width: width, height: height, offset: key.offset)
            await persist(result, disk: disk, key: diskKey, scope: key.scope, ticket: ticket)
            return result
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = values[kCGImagePropertyPixelWidth] as? Int,
              let height = values[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20000, height <= 20000, width * height <= 12_000_000
        else { throw AppError.unsupportedContent }
        let result: CGImage
        if let cropWidth = key.width, let cropHeight = key.height {
            guard let sprite = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw AppError.unsupportedContent }
            try Task.checkCancellation()
            sprites.insert(sprite, for: sourceKey, cost: sprite.bytesPerRow * sprite.height)
            result = try crop(sprite, width: cropWidth, height: cropHeight, offset: key.offset)
        } else {
            guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 640,
                 kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { throw AppError.unsupportedContent }
            result = try raster(decoded)
        }
        try Task.checkCancellation()
        await persist(result, disk: disk, key: diskKey, scope: key.scope, ticket: ticket)
        return result
    }
    private func restore(_ raster: PreviewRaster) -> CGImage? {
        guard let color = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: raster.pixels as CFData) else { return nil }
        return CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: raster.bytesPerRow, space: color,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
    private func persist(_ image: CGImage, disk: PreviewRasterDiskCache?, key: PreviewRasterKey,
                         scope: SessionScope, ticket: UInt64?) async {
        guard let disk, let ticket, image.bytesPerRow == image.width * 4,
              let bytes = image.dataProvider?.data, let pointer = CFDataGetBytePtr(bytes),
              let raster = try? PreviewRaster(width: image.width, height: image.height,
                pixels: Data(bytes: pointer, count: image.bytesPerRow * image.height)) else { return }
        // Cache IO failure never turns a successfully fetched image into a failure.
        try? await disk.write(raster, key: key, scope: scope, ticket: ticket)
    }
    private func crop(_ sprite: CGImage, width: Int, height: Int, offset: Int) throws -> CGImage {
        try Task.checkCancellation()
        guard offset >= 0, offset <= sprite.width, width > 0, height > 0,
              width <= sprite.width - offset, height <= sprite.height,
              let cropped = sprite.cropping(to: CGRect(x: offset, y: 0, width: width, height: height))
        else { throw AppError.parseMismatch }
        // Draw into independent storage: retaining a tiny crop must not retain
        // the entire sprite's backing bitmap outside the source-cache budget.
        return try raster(cropped)
    }
    private func raster(_ image: CGImage) throws -> CGImage {
        let ratio = min(1, 640 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * ratio)), height = max(1, Int(Double(image.height) * ratio))
        guard let color = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw AppError.unsupportedContent }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw AppError.unsupportedContent }
        return result
    }
}
