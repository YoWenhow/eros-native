import Foundation
import ErosCore

/// Prefer the new owner-level location for writes and keep both old site records readable.
struct AccountFileLocations {
    let current: URL
    let legacy: [(site: Site, url: URL)]

    init(root: URL, owner: AccountID, filename: String) throws {
        let directory = root.appendingPathComponent(owner.value.uuidString)
        current = directory.appendingPathComponent(filename)
        legacy = [Site.eh, .ex].map { site in
            (site, directory.appendingPathComponent(site.rawValue).appendingPathComponent(filename))
        }
        let oldPaths = legacy.flatMap { [$0.url.deletingLastPathComponent(), $0.url] }
        guard ([root, directory, current] + oldPaths).allSatisfy({ $0.resolvingSymlinksInPath() == $0 }) else {
            throw AppError.accessDenied
        }
    }

    func records<Value>(decode: (URL) throws -> Value?) throws -> [(url: URL, value: Value, modified: Date)] {
        try ([current] + legacy.map(\.url)).compactMap { url in
            guard let value = try decode(url) else { return nil }
            let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (url, value, modified ?? .distantPast)
        }
    }
}
