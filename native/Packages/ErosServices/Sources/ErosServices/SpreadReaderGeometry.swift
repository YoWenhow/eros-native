import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Shared-height, edge-to-edge images. Only outside the fitted group may letterbox.
public struct SpreadReaderGeometry: Sendable {
    public let frames: [CGRect]
    public init(width: Double, height: Double, aspectRatios: [Double]) {
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              (1...2).contains(aspectRatios.count) else { frames = []; return }
        let ratios = aspectRatios.map { $0.isFinite && $0 > 0 ? min(100_000, max(0.00001, $0)) : 2.0 / 3.0 }
        let sum = ratios.reduce(0, +)
        let fittedHeight = min(height, width / sum)
        var x = (width - fittedHeight * sum) / 2
        let y = (height - fittedHeight) / 2
        frames = ratios.map { ratio in
            let frame = CGRect(x: x, y: y, width: fittedHeight * ratio, height: fittedHeight)
            x += Double(frame.width)
            return frame
        }
    }
}
