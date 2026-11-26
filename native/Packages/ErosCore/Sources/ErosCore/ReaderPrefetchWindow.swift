public enum ReaderPrefetchWindow {
    /// Ordered 0-based image pages after the viewport, regardless of reading direction.
    /// A disabled limit, empty viewport or invalid input yields no work.
    public static func pages(after visiblePages: some Sequence<Int>, pageCount: Int, limit: Int) -> [Int] {
        guard AppPreferences.readerPrefetchPageRange.contains(limit), limit > 0, pageCount > 0 else { return [] }

        var lastVisible = -1
        for page in visiblePages {
            guard (0..<pageCount).contains(page) else { return [] }
            lastVisible = max(lastVisible, page)
        }
        guard lastVisible >= 0 else { return [] }

        let start = lastVisible + 1
        let length = min(limit, pageCount - start)
        return Array(start..<(start + length))
    }
}
