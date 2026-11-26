import Foundation

public enum DownloadLibraryText {
    public static func asciiLowercase(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.map { scalar in
            (65...90).contains(scalar.value) ? Unicode.Scalar(scalar.value + 32)! : scalar
        }))
    }
    public static func normalizedTag(_ value: String) -> String? {
        let nfc = value.precomposedStringWithCanonicalMapping
        let collapsed = nfc.unicodeScalars.split(whereSeparator: { CharacterSet.whitespacesAndNewlines.contains($0) })
            .map { String(String.UnicodeScalarView($0)) }.joined(separator: " ")
        return collapsed.isEmpty ? nil : asciiLowercase(collapsed)
    }
    public static func scalarLess(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.map(\.value).lexicographicallyPrecedes(rhs.unicodeScalars.map(\.value))
    }
    public static func primaryTag(_ tags: [String]) -> String? {
        Set(tags.compactMap(normalizedTag)).min(by: scalarLess)
    }
}

/// Display ordering only; never used by DownloadCoordinator.pump.
public enum DownloadLibrarySort {
    public static let version = 1
    private struct Key {
        let item: DownloadLibraryItem
        let primary: String?
    }
    private static func key(_ item: DownloadLibraryItem, _ field: DownloadSortField) -> Key {
        let tags = field == .artist ? item.metadata.artists : item.metadata.groups
        return Key(item: item, primary: field == .addedAt ? nil : DownloadLibraryText.primaryTag(tags))
    }
    private static func timeOrder(_ a: Int64?, _ b: Int64?, _ direction: DownloadSortDirection) -> Bool? {
        switch (a, b) {
        case (nil, nil): return nil
        case (nil, _): return false
        case (_, nil): return true
        case let (a?, b?): return a == b ? nil : (direction == .ascending ? a < b : a > b)
        }
    }
    private static func less(_ a: Key, _ b: Key, _ sort: DownloadSort) -> Bool {
        if sort.field != .addedAt {
            switch (a.primary, b.primary) {
            case (nil, nil): break
            case (nil, _): return false
            case (_, nil): return true
            case let (x?, y?):
                if x != y { return sort.direction == .ascending ? DownloadLibraryText.scalarLess(x, y) : DownloadLibraryText.scalarLess(y, x) }
            }
        }
        if let order = timeOrder(a.item.addedAt?.value, b.item.addedAt?.value, sort.field == .addedAt ? sort.direction : .descending) { return order }
        return a.item.jobID.uuidString < b.item.jobID.uuidString
    }
    public static func less(_ lhs: DownloadLibraryItem, _ rhs: DownloadLibraryItem, by sort: DownloadSort) -> Bool {
        less(key(lhs, sort.field), key(rhs, sort.field), sort)
    }
    public static func sorted(_ items: [DownloadLibraryItem], by sort: DownloadSort) -> [DownloadLibraryItem] {
        // Compute normalized keys once per item, not once per comparator call.
        items.map { key($0, sort.field) }.sorted { less($0, $1, sort) }.map(\.item)
    }
}
