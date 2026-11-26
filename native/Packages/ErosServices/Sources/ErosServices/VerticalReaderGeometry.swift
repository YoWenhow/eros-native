import Foundation

/// Geometry stores numbers only, never image data or signed addresses.
public struct VerticalReaderGeometry: Sendable {
    public let offsets: [Double]
    public let heights: [Double]
    public let width: Double
    public var count: Int { heights.count }
    public var totalHeight: Double { (offsets.last ?? 0) + (heights.last ?? 0) }
    public init(count: Int, width: Double, ratios: [Int: Double] = [:]) {
        self.width = max(1, width)
        var offsets: [Double] = [], heights: [Double] = [], y = 0.0
        for index in 0..<max(0, count) {
            let raw = ratios[index] ?? 1.5
            let ratio = raw.isFinite && raw > 0 ? raw : 1.5
            let height = max(120, self.width * min(100, ratio))
            offsets.append(y); heights.append(height); y += height + 8
        }
        self.offsets = offsets; self.heights = heights
    }
    public func anchor(at y: Double) -> (index: Int, fraction: Double) {
        guard count > 0 else { return (0, 0) }
        let value = y.isFinite ? max(0, y) : 0
        var lower = 0, upper = count
        while lower + 1 < upper {
            let mid = (lower + upper) / 2
            if offsets[mid] <= value { lower = mid } else { upper = mid }
        }
        return (lower, min(1, max(0, (value - offsets[lower]) / heights[lower])))
    }
    public func offset(index: Int, fraction: Double = 0) -> Double {
        guard count > 0 else { return 0 }
        let index = min(count - 1, max(0, index))
        return offsets[index] + heights[index] * (fraction.isFinite ? min(1, max(0, fraction)) : 0)
    }
    /// Pages with positive intersection with the viewport. Tile gaps and
    /// edges touching the viewport contribute no visible page.
    public func visible(from: Double, to: Double) -> ClosedRange<Int>? {
        guard count > 0, from.isFinite, to.isFinite, from < to else { return nil }
        let top = anchor(at: from).index, bottom = anchor(at: to).index
        let first = offsets[top] + heights[top] <= from ? top + 1 : top
        let last = offsets[bottom] >= to ? bottom - 1 : bottom
        guard first <= last else { return nil }
        return first...last
    }
    public func retained(around index: Int) -> Set<Int> {
        guard count > 0 else { return [] }
        let index = min(count - 1, max(0, index))
        return Set(max(0, index - 2)...min(count - 1, index + 2))
    }
}
