import Foundation

/// Independent of ReadingMode: direction/vertical retain their existing persisted values.
public enum ReaderLayoutMode: String, Codable, CaseIterable, Sendable { case singlePage, doublePage }
public struct ReaderLayoutPreferences: Codable, Equatable, Sendable {
    public var mode: ReaderLayoutMode = .singlePage
    public var coverAlone = true
    public init(mode: ReaderLayoutMode = .singlePage, coverAlone: Bool = true) {
        self.mode = mode; self.coverAlone = coverAlone
    }
    private enum CodingKeys: String, CodingKey { case mode, coverAlone }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(ReaderLayoutMode.self, forKey: .mode) ?? .singlePage
        coverAlone = try c.decodeIfPresent(Bool.self, forKey: .coverAlone) ?? true
    }
}
public enum ReaderViewportOrientation: Sendable { case portrait, landscape }
public enum HorizontalPageSwipe: Sendable { case left, right }
public enum SpreadNavigation: Sendable { case previous, next }

public struct ReaderSpread: Equatable, Sendable {
    /// Transient layout ordinal, never a ReadingProgress.index.
    public let index: Int
    /// Stable gallery order, regardless of reading direction.
    public let logicalPages: [PageIndex]
    /// Left-to-right visual order; single-page spreads have no invented blank page.
    public let displayPages: [PageIndex]
    fileprivate init(index: Int, pages: [PageIndex], rightToLeft: Bool) {
        self.index = index; logicalPages = pages; displayPages = rightToLeft ? Array(pages.reversed()) : pages
    }
}
public struct SpreadPosition: Equatable, Sendable {
    public let spread: ReaderSpread
    /// Exact logical anchor to persist and use after rotation/layout changes.
    public let mainPage: PageIndex
    fileprivate init(spread: ReaderSpread, mainPage: PageIndex) { self.spread = spread; self.mainPage = mainPage }
}

/// O(1) arithmetic per lookup; no allocation proportional to the gallery page count.
public struct SpreadLayoutPolicy: Sendable {
    public let pageCount: Int
    public let readingMode: ReadingMode
    public let preferences: ReaderLayoutPreferences
    public let usesDoublePage: Bool
    public init(pageCount: Int, readingMode: ReadingMode, preferences: ReaderLayoutPreferences = ReaderLayoutPreferences(),
                orientation: ReaderViewportOrientation) throws {
        guard pageCount >= 0 else { throw AppError.invalidInput }
        self.pageCount = pageCount; self.readingMode = readingMode; self.preferences = preferences
        usesDoublePage = preferences.mode == .doublePage && orientation == .landscape && readingMode != .vertical
    }
    public var spreadCount: Int {
        guard usesDoublePage, pageCount > 0 else { return pageCount }
        let paired = preferences.coverAlone ? pageCount - 1 : pageCount
        return paired / 2 + paired % 2 + (preferences.coverAlone ? 1 : 0)
    }
    public var forwardSwipe: HorizontalPageSwipe? {
        switch readingMode {
        case .leftToRight: .left
        case .rightToLeft: .right
        case .vertical: nil
        }
    }
    public func spreadIndex(for page: PageIndex) throws -> Int {
        _ = try page.checked(pageCount: pageCount)
        guard usesDoublePage else { return page.value }
        if preferences.coverAlone { return page.value == 0 ? 0 : 1 + (page.value - 1) / 2 }
        return page.value / 2
    }
    public func spread(at index: Int) throws -> ReaderSpread {
        guard index >= 0, index < spreadCount else { throw AppError.invalidInput }
        let first: Int
        if !usesDoublePage { first = index }
        else if preferences.coverAlone { first = index == 0 ? 0 : (index - 1) * 2 + 1 }
        else { first = index * 2 }
        var pages = [try PageIndex(first)]
        if usesDoublePage, !(preferences.coverAlone && index == 0), first < pageCount - 1 {
            pages.append(try PageIndex(first + 1))
        }
        return ReaderSpread(index: index, pages: pages, rightToLeft: readingMode == .rightToLeft)
    }
    public func position(for mainPage: PageIndex) throws -> SpreadPosition {
        SpreadPosition(spread: try spread(at: spreadIndex(for: mainPage)), mainPage: mainPage)
    }
    /// New navigation defaults to the first logical page. Reuse an explicit anchor when restoring.
    public func position(at index: Int, preferredMainPage: PageIndex? = nil) throws -> SpreadPosition {
        let value = try spread(at: index)
        let anchor = preferredMainPage ?? value.logicalPages[0]
        guard value.logicalPages.contains(anchor) else { throw AppError.invalidInput }
        return SpreadPosition(spread: value, mainPage: anchor)
    }
    public func neighbor(from mainPage: PageIndex, direction: SpreadNavigation) throws -> SpreadPosition? {
        let index = try spreadIndex(for: mainPage)
        switch direction {
        case .previous: return index == 0 ? nil : try position(at: index - 1)
        case .next: return index == spreadCount - 1 ? nil : try position(at: index + 1)
        }
    }
}
