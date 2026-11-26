import ErosCore

/// Physical scroll positions stay stable for the lifetime of a layout.
public struct ReaderPagingTrack: Equatable, Sendable {
    private let layout: SpreadLayoutPolicy

    public init(policy: SpreadLayoutPolicy) { layout = policy }

    public var count: Int { layout.spreadCount }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.layout.pageCount == rhs.layout.pageCount &&
            lhs.layout.readingMode == rhs.layout.readingMode &&
            lhs.layout.usesDoublePage == rhs.layout.usesDoublePage &&
            lhs.layout.preferences.coverAlone == rhs.layout.preferences.coverAlone
    }

    public func index(for page: Int) -> Int? {
        guard let page = try? PageIndex(page), let ordinal = try? layout.spreadIndex(for: page) else { return nil }
        return physicalIndex(ordinal)
    }

    public func position(at index: Int) -> SpreadPosition? {
        guard (0..<count).contains(index) else { return nil }
        return try? layout.position(at: physicalIndex(index))
    }

    /// Keep a one-page radius around the viewport’s nearest page.
    public func nearbyIndices(at offset: Double) -> ClosedRange<Int>? {
        guard count > 0, offset.isFinite else { return nil }
        let center = boundedIndex(offset.rounded())
        return max(0, center - 1)...min(count - 1, center + 1)
    }

    public func visibleIndices(at offset: Double) -> ClosedRange<Int>? {
        guard count > 0, offset.isFinite else { return nil }
        return boundedIndex(offset.rounded(.down))...boundedIndex(offset.rounded(.up))
    }

    public func settledIndex(at offset: Double) -> Int? {
        guard count > 0, offset.isFinite else { return nil }
        let index = boundedIndex(offset.rounded())
        return abs(offset - Double(index)) < 0.01 ? index : nil
    }

    private func physicalIndex(_ index: Int) -> Int {
        layout.readingMode == .rightToLeft ? count - 1 - index : index
    }

    private func boundedIndex(_ integralOffset: Double) -> Int {
        if integralOffset <= 0 { return 0 }
        if integralOffset >= Double(count - 1) { return count - 1 }
        return Int(integralOffset)
    }
}
