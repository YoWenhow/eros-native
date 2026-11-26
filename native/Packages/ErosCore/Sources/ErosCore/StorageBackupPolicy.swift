import Foundation

/// Apply backup policy to a whole directory so atomic replacement of its
/// children does not reset the policy.
public enum StorageBackupPolicy: Equatable, Sendable {
    case included
    case excluded

    public func apply(toDirectory directory: URL) throws {
        #if os(iOS)
        var url = URL(fileURLWithPath: directory.path)
        let current = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isExcludedFromBackupKey])
        guard current.isDirectory == true, current.isSymbolicLink != true else { throw AppError.accessDenied }
        let excluded = self == .excluded
        guard current.isExcludedFromBackup != excluded else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try url.setResourceValues(values)
        #endif
    }
}
