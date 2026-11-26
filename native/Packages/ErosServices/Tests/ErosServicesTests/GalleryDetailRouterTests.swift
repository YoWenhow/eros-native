import Foundation
import XCTest
import ErosCore
import ErosServices

private actor RoutedDetailRepository: GalleryRepository {
    let failure: AppError?
    private(set) var detailSites: [Site] = []
    private(set) var previewSites: [Site] = []

    init(failure: AppError? = nil) { self.failure = failure }
    func list(request: GalleryListRequest) throws -> PagedResult<GallerySummary> { throw AppError.notFound }
    func readerPages(request: ReaderPagesRequest) throws -> PagedResult<ReaderPage> { throw AppError.notFound }

    func detail(request: GalleryRequest) throws -> GalleryDetail {
        detailSites.append(request.scope.storage.site)
        if let failure { throw failure }
        return GalleryDetail(summary: try GallerySummary(reference: request.reference, title: "Synthetic detail"))
    }

    func thumbnails(request: ReaderPagesRequest) throws -> PagedResult<GalleryThumbnail> {
        previewSites.append(request.context.scope.storage.site)
        return try PagedResult(items: [], context: request.context)
    }
}

private func preferredTestSource(_ request: GalleryRequest, repository: any GalleryRepository) throws -> GalleryDetailReadSource {
    let eh = SessionScope(storage: StorageScope(accountID: request.scope.storage.accountID, site: .eh), generation: 2)
    let ref = GalleryReference(key: GalleryKey(site: .eh, galleryID: request.reference.key.galleryID),
                               token: request.reference.token)
    return GalleryDetailReadSource(request: try GalleryRequest(reference: ref, scope: eh), repository: repository)
}

@MainActor final class GalleryDetailRouterTests: XCTestCase {
    private func makeInput(_ site: Site) throws -> (SessionScope, GalleryReference, MutableSessionProvider) {
        let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: site), generation: 1)
        let reference = GalleryReference(key: GalleryKey(site: site, galleryID: try GalleryID(41)),
                                         token: try SensitiveText("0a1234b567"))
        return (scope, reference, MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated)))
    }

    func testEHPreferredForDetailsAndPreviewsWhilePresentationUsesEX() async throws {
        let (scope, reference, sessions) = try makeInput(.ex)
        let eh = RoutedDetailRepository(), ex = RoutedDetailRepository()
        let router = GalleryDetailRouter(sessions: sessions) { request in
            try preferredTestSource(request, repository: eh)
        }
        let model = GalleryDetailViewModel(repository: ex, router: router)
        await model.load(reference: reference, scope: scope)
        XCTAssertEqual(model.detailSite, .eh)
        XCTAssertEqual(model.detail?.summary.reference, reference)
        XCTAssertEqual(model.context?.scope, scope)
        let ehRequests = await eh.detailSites, ehPreviews = await eh.previewSites, exRequests = await ex.detailSites
        XCTAssertEqual(ehRequests, [.eh])
        XCTAssertEqual(ehPreviews, [.eh])
        XCTAssertTrue(exRequests.isEmpty)
    }

    func testFallbackRemembersGalleryUnavailableOnEHForThisEXSession() async throws {
        let (scope, reference, sessions) = try makeInput(.ex)
        let eh = RoutedDetailRepository(failure: .notFound), ex = RoutedDetailRepository()
        let router = GalleryDetailRouter(sessions: sessions) { request in
            try preferredTestSource(request, repository: eh)
        }
        let model = GalleryDetailViewModel(repository: ex, router: router)
        await model.load(reference: reference, scope: scope)
        XCTAssertEqual(model.detailSite, .ex)
        await model.load(reference: reference, scope: scope)
        let ehRequests = await eh.detailSites, exRequests = await ex.detailSites, exPreviews = await ex.previewSites
        XCTAssertEqual(ehRequests, [.eh])
        XCTAssertEqual(exRequests, [.ex, .ex])
        XCTAssertEqual(exPreviews, [.ex, .ex])
    }

    func testTransportFailureDoesNotSwitchAndDisabledPreferenceUsesEX() async throws {
        let (scope, reference, sessions) = try makeInput(.ex)
        let eh = RoutedDetailRepository(failure: .transport(code: -1001)), ex = RoutedDetailRepository()
        let router = GalleryDetailRouter(sessions: sessions) { request in
            try preferredTestSource(request, repository: eh)
        }
        let model = GalleryDetailViewModel(repository: ex, router: router)
        await model.load(reference: reference, scope: scope)
        XCTAssertEqual(model.error, .transport(code: -1001))
        let exBeforeOptOut = await ex.detailSites
        XCTAssertTrue(exBeforeOptOut.isEmpty)
        let optedOut = GalleryDetailViewModel(repository: ex, router: GalleryDetailRouter(sessions: sessions) { _ in nil })
        await optedOut.load(reference: reference, scope: scope)
        XCTAssertEqual(optedOut.detailSite, .ex)
        let exRequests = await ex.detailSites
        XCTAssertEqual(exRequests, [.ex])
    }

    func testDirectEHAccessNeverAttemptsAnAlternateSite() async throws {
        let (scope, reference, sessions) = try makeInput(.eh)
        let eh = RoutedDetailRepository(failure: .notFound)
        let router = GalleryDetailRouter(sessions: sessions) { _ in
            XCTFail("Direct EH requests must stay on EH")
            return nil
        }
        let model = GalleryDetailViewModel(repository: eh, router: router)
        await model.load(reference: reference, scope: scope)
        XCTAssertEqual(model.error, .notFound)
        let requests = await eh.detailSites
        XCTAssertEqual(requests, [.eh])
    }
}
