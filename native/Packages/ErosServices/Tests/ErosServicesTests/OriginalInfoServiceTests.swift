import Foundation
import XCTest
import ErosCore
import ErosNetworking
import ErosServices

private actor OriginalInfoTransport: HTTPTransport {
    private(set) var urls: [URL] = []
    func send(request: HTTPRequest) throws -> HTTPResponse {
        urls.append(request.url)
        let html="<html><body><div id='i2'><div class='sn'><div><span>1</span><span>1</span></div></div></div><div id='i3'><img id='img' src='https://media.example.invalid/i.jpg'></div><div id='i5'><div><a href='/g/42/synthetic/'>Gallery</a></div></div><a href='/fullimg.php?gid=42&amp;page=1&amp;key=synthetic'>Download original</a></body></html>"
        return try HTTPResponse(requestID:request.id,scope:request.scope,status:200,headers:["Content-Type":"text/html"],body:Data(html.utf8),finalURL:request.url)
    }
    func requests() -> [URL] { urls }
}

@MainActor final class OriginalInfoServiceTests: XCTestCase {
    func testInfoFetchesOnlyNormalPageAndLocalOnlyOrUnsafeEntryCannotSend() async throws {
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1)
        let provider=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        let transport=OriginalInfoTransport(),policy=NetworkPolicy(parsing:ParsingPolicy(ehHost:"eh.example.invalid",exHost:"ex.example.invalid"))
        let service=OriginalImageInfoService(client:HTTPClient(transport:transport,policy:policy),sessions:provider)
        let reference=GalleryReference(key:GalleryKey(site:.ex,galleryID:try GalleryID(42)),token:try SensitiveText("synthetic"))
        let page=ReaderPage(reference:reference,index:try PageIndex(0),pageURL:URL(string:"https://ex.example.invalid/s/synthetic/42-1")!)
        let info=try await service.info(page:page,scope:scope)
        XCTAssertEqual(info.availability,.offered);XCTAssertEqual(info.quota,.unknown)
        let sent=await transport.requests();XCTAssertEqual(sent,[page.pageURL])
        let malicious=ReaderPage(reference:reference,index:try PageIndex(0),pageURL:try info.requireLink())
        do {_=try await service.info(page:malicious,scope:scope);XCTFail()} catch {XCTAssertEqual(error as? AppError,.accessDenied)}
        await provider.update(SessionState(scope:scope,authentication:.authenticated,permitsNetwork:false))
        do {_=try await service.info(page:page,scope:scope);XCTFail()} catch {XCTAssertEqual(error as? AppError,.authenticationRequired)}
        let final=await transport.requests();XCTAssertEqual(final.count,1)
    }
}
