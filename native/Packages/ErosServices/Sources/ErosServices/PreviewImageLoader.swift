import Foundation
import ErosCore
import ErosNetworking

/// Small preview-only memory cache. Never inject account credentials into media requests.
public actor PreviewImageLoader {
    public static let productionPolicy = NetworkPolicy(mediaHosts: ["ehgt.org", "s.exhentai.org"], allowHathThumbnailSprites: true)
    private struct Key: Hashable { let url: URL; let scope: SessionScope }
    public let diskCache: PreviewRasterDiskCache?
    private let client: HTTPClient
    private let sessions: any SessionProvider
    private let policy: NetworkPolicy
    private var cache: ReaderMemoryCache<Key, Data>
    private var pending: [Key: Task<Data, any Error>] = [:]
    public init(sessions: any SessionProvider, policy: NetworkPolicy, transport: (any HTTPTransport)? = nil, cacheMaximumBytes: Int = 32 * 1024 * 1024, cacheMaximumCount: Int = 256, diskCacheRoot: URL? = nil) {
        self.sessions = sessions; self.policy = policy
        diskCache = diskCacheRoot.map { PreviewRasterDiskCache(root: $0, sessions: sessions) }
        cache = ReaderMemoryCache(maximumCost: cacheMaximumBytes, maximumCount: cacheMaximumCount)
        client = HTTPClient(transport: transport ?? URLSessionTransport(policy: policy), policy: policy)
    }
    /// Known static thumbnail routes only. Never translate gallery, account or arbitrary URLs.
    public static func publicMirror(for url: URL) -> URL? {
        guard url.scheme == "https", url.host == "s.exhentai.org", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.query == nil, url.fragment == nil else { return nil }
        let path = url.path
        let modern = #"^/w/[0-9a-f]{2}/[0-9a-f]{3}/[0-9a-f]{5}-[A-Za-z0-9_-]{1,64}\.(webp|jpg|png|gif)$"#
        let legacy = #"^/t/[0-9a-f]{2}/[0-9a-f]{2}/[0-9a-f]{40}-[0-9]+-[0-9]+-[0-9]+-[A-Za-z0-9_]+\.(jpg|png|gif)$"#
        let target: String
        if path.range(of: modern, options: .regularExpression) != nil { target = path }
        else if path.range(of: legacy, options: .regularExpression) != nil { target = String(path.dropFirst(2)) }
        else { return nil }
        var parts = URLComponents(); parts.scheme = "https"; parts.host = "ehgt.org"; parts.path = target
        return parts.url
    }
    public func validate(scope: SessionScope) async throws {
        try Task.checkCancellation()
        guard try await sessions.current().scope == scope else { throw AppError.staleSession }
    }
    public func clearCache() {for task in pending.values{task.cancel()};pending.removeAll();cache.clear()}
    public func load(url: URL, scope: SessionScope) async throws -> Data {
        try await validate(scope: scope)
        let key = Key(url: url, scope: scope)
        if let value = cache.value(for: key) { return value }
        if let task = pending[key] {
            let value = try await task.value
            try Task.checkCancellation()
            guard try await sessions.current().scope == scope else { throw AppError.staleSession }
            return value
        }
        guard try await sessions.current().permitsNetwork else{throw AppError.authenticationRequired}
        let builder = EndpointBuilder(policy: policy)
        let request = try builder.media(url: url, scope: scope), client = self.client
        let task = Task {
            let result: HTTPResponse
            do { result = try await client.send(request, expecting: .image) }
            catch {
                guard let failure = error as? AppError, let mirror = Self.publicMirror(for: url) else { throw error }
                switch failure {
                case .imageExpired, .accessDenied, .transport:
                    let current=try await sessions.current()
                    guard current.scope==scope,current.permitsNetwork else{throw AppError.staleSession}
                    result = try await client.send(builder.media(url: mirror, scope: scope), expecting: .image)
                default: throw error
                }
            }
            guard result.body.count <= 12 * 1024 * 1024 else { throw AppError.unsupportedContent }
            return result.body
        }
        pending[key] = task
        defer { pending[key] = nil }
        let value = try await task.value
        guard try await sessions.current().scope == scope else { throw AppError.staleSession }
        cache.insert(value, for: key, cost: value.count)
        try Task.checkCancellation(); return value
    }
}
