import ErosCore

public struct GalleryDetailReadSource: Sendable {
    public let request: GalleryRequest
    let repository: any GalleryRepository

    public init(request: GalleryRequest, repository: any GalleryRepository) {
        self.request = request
        self.repository = repository
    }
}

struct RoutedGalleryDetail: Sendable {
    let detail: GalleryDetail
    let source: GalleryDetailReadSource
}

/// Selects the read side of the detail screen. A different site never supplies mutation state.
public actor GalleryDetailRouter {
    private let sessions: SessionGuard
    private let ehSource: @Sendable (GalleryRequest) async throws -> GalleryDetailReadSource?
    private var exOnlyScope: SessionScope?
    private var exOnly: Set<GalleryReference> = []

    public init(sessions: any SessionProvider,
                ehSource: @escaping @Sendable (GalleryRequest) async throws -> GalleryDetailReadSource?) {
        self.sessions = SessionGuard(provider: sessions)
        self.ehSource = ehSource
    }

    func load(_ original: GalleryDetailReadSource) async throws -> RoutedGalleryDetail {
        let request = original.request
        try await sessions.checkNetwork(request.scope)
        if exOnlyScope != request.scope {
            exOnlyScope = request.scope
            exOnly.removeAll()
        }
        if request.scope.storage.site == .ex, !exOnly.contains(request.reference),
           let target = try await ehSource(request) {
            guard target.request.scope.storage.accountID == request.scope.storage.accountID,
                  target.request.scope.storage.site == .eh,
                  target.request.reference.key.galleryID == request.reference.key.galleryID,
                  target.request.reference.token == request.reference.token else { throw AppError.scopeMismatch }
            var absentOnEH = false
            do {
                let remote = try await fetch(target)
                try await sessions.checkNetwork(request.scope)
                return RoutedGalleryDetail(detail: try present(remote, reference: request.reference), source: target)
            } catch let error as AppError {
                switch error {
                case .notFound, .httpStatus(404), .httpStatus(410): absentOnEH = true
                case .accessDenied, .authenticationRequired: break
                default: throw error
                }
            }
            try await sessions.checkNetwork(request.scope)
            let fallback = try await fetch(original)
            try await sessions.checkNetwork(request.scope)
            if absentOnEH, exOnlyScope == request.scope {
                if exOnly.count == 256 { exOnly.removeAll(keepingCapacity: true) }
                exOnly.insert(request.reference)
            }
            return RoutedGalleryDetail(detail: fallback, source: original)
        }

        let detail = try await fetch(original)
        try await sessions.checkNetwork(request.scope)
        return RoutedGalleryDetail(detail: detail, source: original)
    }

    private func fetch(_ source: GalleryDetailReadSource) async throws -> GalleryDetail {
        let detail = try await source.repository.detail(request: source.request)
        try Task.checkCancellation()
        guard detail.summary.reference == source.request.reference else { throw AppError.parseMismatch }
        return detail
    }

    private func present(_ detail: GalleryDetail, reference: GalleryReference) throws -> GalleryDetail {
        let original = detail.summary
        let summary = try GallerySummary(reference: reference, title: original.title, coverURL: original.coverURL,
            category: original.category, uploader: original.uploader, pageCount: original.pageCount, rating: original.rating,
            listTags: original.listTags, postedAt: original.postedAt, sourceTitles: original.sourceTitles)
        return GalleryDetail(summary: summary, originalTitle: detail.originalTitle, translatedTitle: detail.translatedTitle,
            tags: detail.tags, thumbnailPageCount: detail.thumbnailPageCount, availability: detail.availability,
            sourceTitles: detail.sourceTitles)
    }
}
