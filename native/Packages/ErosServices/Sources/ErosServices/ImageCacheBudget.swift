import Foundation

/// One aggregate disk budget across reader and thumbnail roots. Zero is unlimited.
public actor ImageCacheBudget {
    public static let shared = ImageCacheBudget()
    private var roots: [URL] = []
    private var pending: Task<Void, Never>?
    private var limit = 0
    private var lastTrim = Date.distantPast
    public init() {}
    public func configure(roots: [URL], mebibytes: Int) throws {
        pending?.cancel(); pending = nil
        self.roots = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        limit = max(0, mebibytes) * 1024 * 1024
        try trim()
    }
    public func trimIfManaged(root: URL) throws -> Bool {
        guard roots.contains(root.standardizedFileURL.resolvingSymlinksInPath()) else { return false }
        if Date().timeIntervalSince(lastTrim) >= 1 { try trim() }
        else if pending == nil, limit > 0 {
            pending = Task {
                do { try await Task.sleep(for: .seconds(1)); try trim() } catch {}
                pending = nil
            }
        }
        return true
    }
    private func trim() throws {
        lastTrim = Date()
        guard limit > 0 else { return }
        var files: [(URL, Int, Date)] = []
        for root in roots {
            guard root.resolvingSymlinksInPath() == root,
                  let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey,.contentModificationDateKey]) else { continue }
            for case let file as URL in iterator {
                guard let info = try? file.resourceValues(forKeys: [.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey,.contentModificationDateKey]) else { continue }
                if info.isSymbolicLink == true { iterator.skipDescendants(); continue }
                if info.isRegularFile == true { files.append((file,info.fileSize ?? 0,info.contentModificationDate ?? .distantPast)) }
            }
        }
        var total = files.reduce(0) { $0 + $1.1 }
        for file in files.sorted(by: { $0.2 < $1.2 }) where total > limit {
            try? FileManager.default.removeItem(at: file.0); total -= file.1
        }
    }
}
