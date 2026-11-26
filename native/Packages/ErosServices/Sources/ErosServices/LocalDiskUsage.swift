import Foundation
import ErosCore

public enum LocalDiskUsage {
    public static func bytes(in directory: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AppError.accessDenied }
        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        var result: Int64 = 0
        for url in try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw AppError.accessDenied }
            if values.isDirectory == true { result += try bytes(in: url) }
            else if values.isRegularFile == true { result += Int64(values.fileSize ?? 0) }
        }
        return result
    }
}
