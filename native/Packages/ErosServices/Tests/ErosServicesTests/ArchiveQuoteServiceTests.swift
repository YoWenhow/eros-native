import Foundation
import Testing
import ErosCore
import ErosNetworking
import ErosServices

private actor ArchiveQuoteTransport: HTTPTransport {
    var sent:[HTTPRequest]=[]
    let changedSession:MutableSessionProvider?
    init(changedSession:MutableSessionProvider?=nil) { self.changedSession=changedSession }
    func send(request:HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        if let changedSession { await changedSession.update(SessionState(scope:try request.scope.advanced(),authentication:.authenticated)) }
        let action=request.url.absoluteString.replacingOccurrences(of:"&",with:"&amp;")
        let html="<html><body><div id='db'><div><div>Download Cost: <strong>23 GP</strong></div><form method='post' action='\(action)'><input type='hidden' name='dltype' value='org'><div><input type='submit' name='dlcheck' value='Download Original Archive'></div></form><p>Estimated Size: <strong>1 MiB</strong></p></div></div></body></html>"
        return try HTTPResponse(requestID:request.id,scope:request.scope,status:200,headers:["Content-Type":"text/html"],body:Data(html.utf8),finalURL:request.url)
    }
    func requests()->[HTTPRequest] { sent }
}
struct ArchiveQuoteServiceTests {
    let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1)
    let policy=NetworkPolicy(parsing:ParsingPolicy(ehHost:"eh.example.invalid",exHost:"ex.example.invalid"))
    func request() throws -> GalleryRequest { try GalleryRequest(reference:GalleryReference(key:GalleryKey(site:.ex,galleryID:GalleryID(42)),token:SensitiveText("synthetic")),scope:scope) }
    @Test func quoteIsOneGETWithNoCreationOrArchiveFileFetch() async throws {
        let session=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated)),transport=ArchiveQuoteTransport()
        let service=ArchiveQuoteService(client:HTTPClient(transport:transport,policy:policy),sessions:session)
        let offers=try await service.read(request()),sent=await transport.requests()
        #expect(offers.count==1 && offers[0].quote.price == .amount(23,currency:"GP"))
        #expect(sent.count==1 && sent[0].method == .get && sent[0].body == nil && sent[0].url.path=="/archiver.php")
    }
    @Test func localOnlyNeverSends() async throws {
        let session=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated,permitsNetwork:false)),transport=ArchiveQuoteTransport()
        let service=ArchiveQuoteService(client:HTTPClient(transport:transport,policy:policy),sessions:session)
        await #expect(throws:AppError.authenticationRequired) { _=try await service.read(request()) }
        #expect(await transport.requests().isEmpty)
    }
    @Test func switchedSessionCannotPublishOldQuote() async throws {
        let session=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated)),transport=ArchiveQuoteTransport(changedSession:session)
        let service=ArchiveQuoteService(client:HTTPClient(transport:transport,policy:policy),sessions:session)
        await #expect(throws:AppError.staleSession) { _=try await service.read(request()) }
    }
}
