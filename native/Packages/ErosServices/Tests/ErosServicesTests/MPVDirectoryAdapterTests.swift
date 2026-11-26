import Foundation
import XCTest
import ErosCore
import ErosServices

final class MPVDirectoryAdapterTests: XCTestCase, @unchecked Sendable {
    func testReplacementAndInvalidationRejectLateResponses() async throws {
        let adapter = MPVDirectoryAdapter()
        let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
        let old = await adapter.begin(scope: scope)
        let current = await adapter.begin(scope: scope)
        let ref = GalleryReference(key: GalleryKey(site: .eh, galleryID: try GalleryID(42)), token: try SensitiveText("synthetic"))
        let html = #"<script>var gid=42;var mpvkey="syntheticmpv";var imagelist=[{"n":"p","k":"syntheticpage","t":"unused"}];var api_url="https://api.e-hentai.org/api.php";</script>"#
        let response = try HTTPResponse(requestID: UUID(), scope: scope, status: 200, headers: ["Content-Type":"text/html"], body: Data(html.utf8), finalURL: URL(string: "https://e-hentai.org/mpv/42/synthetic/")!)
        do { try await adapter.accept(response, reference: ref, ticket: old, expectedCount: 1); XCTFail() } catch {}
        try await adapter.accept(response, reference: ref, ticket: current, expectedCount: 1)
        let page = try await adapter.page(at: PageIndex(0), ticket: current)
        XCTAssertEqual(page.wirePage, 1)
        await adapter.invalidate()
        let capability = await adapter.capability(); XCTAssertEqual(capability, .unknown)
        do { _ = try await adapter.page(at: PageIndex(0), ticket: current); XCTFail() } catch {}
        do { try await adapter.accept(response, reference: ref, ticket: current, expectedCount: 1); XCTFail() } catch {}
    }
    func testCancelledTaskCannotPublish() async throws {
        let adapter = MPVDirectoryAdapter()
        let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
        let ticket = await adapter.begin(scope: scope)
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await adapter.page(at: PageIndex(0), ticket: ticket)
        }
        do { _ = try await work.value; XCTFail() } catch is CancellationError {} catch { XCTFail("Expected cancellation") }
        let capability = await adapter.capability(); XCTAssertEqual(capability, .unknown)
    }
}
