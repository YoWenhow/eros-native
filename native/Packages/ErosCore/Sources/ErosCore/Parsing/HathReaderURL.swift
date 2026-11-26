import Foundation

/// Reader media only. The captured peer URLs use two DNS labels and high TLS
/// ports; this exception must never relax gallery/login URL validation.
public enum HathReaderURL {
    public static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.fragment == nil, let host = url.host?.lowercased(),
              url.port == nil || url.port == 443 || (1024...65535).contains(url.port!),
              url.path.rangeOfCharacter(from: .controlCharacters) == nil,
              url.path.hasPrefix("/h/"), url.path.split(separator: "/").count >= 3 else { return false }
        let label = #"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"#
        return host.range(of: "^" + label + "(?:\\." + label + ")?\\.hath\\.network$", options: .regularExpression) != nil
    }
}

extension HathReaderURL {
    /// The site's origin image layout. Callers still have to prove the URL
    /// came from the current image page's reload request.
    public static func allowsOriginImage(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.query == nil, url.fragment == nil,
              let host = url.host?.lowercased(),
              host.wholeMatch(of: #/(?:[a-z0-9]{10}|[a-z0-9]{20})\.hath\.network/#) != nil,
              let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else {
            return false
        }

        // /om/file-index/original-descriptor/rendition/size/dispatch-token/filename
        let parts = encodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 8, parts[0].isEmpty, parts[1] == "om",
              parts[2].wholeMatch(of: #/[1-9][0-9]*/#) != nil,
              isFileDescriptor(parts[3]),
              parts[6].wholeMatch(of: #/[A-Za-z0-9]{1,128}/#) != nil,
              let filename = parts[7].removingPercentEncoding, !filename.isEmpty,
              filename != ".", filename != "..", !filename.contains("/"), !filename.contains("\\"),
              filename.rangeOfCharacter(from: .controlCharacters) == nil else { return false }

        if parts[4] == "x" { return parts[5] == "0" }
        return isFileDescriptor(parts[4]) && parts[5].wholeMatch(of: #/[1-9][0-9]*/#) != nil
    }

    private static func isFileDescriptor(_ value: Substring) -> Bool {
        value.wholeMatch(of: #/[0-9a-f]{40}-[1-9][0-9]*-[1-9][0-9]*-[1-9][0-9]*-[a-z0-9]{2,8}/#) != nil
    }
}
