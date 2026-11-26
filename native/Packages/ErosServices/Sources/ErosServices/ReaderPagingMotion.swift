/// Horizontal paging in viewport-width units. A new drag takes over the
/// visible position while retaining the target of the last completed gesture.
public struct ReaderPagingMotion: Sendable {
    private struct Settlement: Sendable {
        let origin: Double
        let startedAt: Double
        let duration: Double
        let initialSlope: Double
    }

    public private(set) var position: Double
    public private(set) var targetIndex: Int
    public var isDragging: Bool { dragOrigin != nil }
    public var isSettling: Bool { settlement != nil }

    private let lastIndex: Int
    private var dragOrigin: Double?
    private var settlement: Settlement?

    public init(pageCount: Int = 0, index: Int = 0) {
        lastIndex = max(1, pageCount) - 1
        targetIndex = min(lastIndex, max(0, index))
        position = Double(targetIndex)
    }

    public mutating func beginDrag() {
        settlement = nil
        let edge = min(Double(lastIndex), max(0, position))
        let stretch = position - edge
        dragOrigin = edge + 0.32 * stretch / (0.18 - abs(stretch))
    }

    /// Motion is measured in a fixed coordinate space in points.
    public mutating func drag(by distance: Double, viewportWidth: Double) {
        guard let dragOrigin, viewportWidth > 0, distance.isFinite else { return }
        let offset = dragOrigin + distance / viewportWidth
        let edge = min(Double(lastIndex), max(0, offset))
        let overflow = offset - edge
        position = edge + 0.18 * (overflow / (abs(overflow) + 0.32))
    }

    @discardableResult
    public mutating func endDrag(distance: Double, velocity: Double, viewportWidth: Double,
                                at time: Double, reduceMotion: Bool = false) -> Int? {
        guard isDragging else { return nil }
        drag(by: distance, viewportWidth: viewportWidth)
        dragOrigin = nil
        if viewportWidth > 0, distance.isFinite, velocity.isFinite {
            let deliberate = abs(distance) >= max(60, 0.18 * viewportWidth)
            let flick = abs(distance) >= 10 && abs(velocity) >= 500 && distance * velocity > 0
            if deliberate || flick {
                targetIndex = min(lastIndex, max(0, targetIndex + (distance > 0 ? 1 : -1)))
            }
        }
        return settle(at: time, velocity: viewportWidth > 0 ? velocity / viewportWidth : 0,
                      reduceMotion: reduceMotion)
    }

    @discardableResult
    public mutating func cancelDrag(at time: Double, reduceMotion: Bool = false) -> Int? {
        guard isDragging else { return nil }
        dragOrigin = nil
        return settle(at: time, velocity: 0, reduceMotion: reduceMotion)
    }

    /// Returns a page only when the viewport has reached the target.
    @discardableResult
    public mutating func advance(to time: Double) -> Int? {
        guard let settlement else { return nil }
        let progress = (time - settlement.startedAt) / settlement.duration
        if progress >= 1 {
            self.settlement = nil
            position = Double(targetIndex)
            return targetIndex
        }
        let t = max(0, progress)
        let slope = settlement.initialSlope
        // Cubic interpolation starts at the release speed and ends at rest.
        let fraction = t * (slope + t * (3 - 2 * slope + t * (slope - 2)))
        position = settlement.origin + (Double(targetIndex) - settlement.origin) * fraction
        return nil
    }

    private mutating func settle(at time: Double, velocity: Double, reduceMotion: Bool) -> Int? {
        let destination = Double(targetIndex)
        let distance = destination - position
        if reduceMotion || abs(distance) < 0.001 {
            position = destination
            settlement = nil
            return targetIndex
        }
        let duration = min(0.23, 0.13 + 0.055 * abs(distance))
        let initialSlope = velocity.isFinite ? min(3, max(0, velocity * duration / distance)) : 0
        settlement = Settlement(origin: position, startedAt: time, duration: duration, initialSlope: initialSlope)
        return nil
    }
}
