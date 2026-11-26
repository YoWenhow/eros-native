import Foundation
import XCTest
import ErosCore
import ErosNetworking
import ErosServices

private struct F19ReaderRepository:GalleryRepository {
    let reference:GalleryReference
    func list(request:GalleryListRequest)throws->PagedResult<GallerySummary>{throw AppError.notFound}
    func detail(request:GalleryRequest)throws->GalleryDetail {try GalleryDetail(summary:GallerySummary(reference:reference,title:"Original sample",pageCount:NonnegativeCount(1)),tags:[])}
    func thumbnails(request:ReaderPagesRequest)throws->PagedResult<GalleryThumbnail>{throw AppError.notFound}
    func readerPages(request:ReaderPagesRequest)throws->PagedResult<ReaderPage> {try PagedResult(items:[ReaderPage(reference:reference,index:PageIndex(0),pageURL:URL(string:"https://ex.example.invalid/s/synthetic/42-1")!)],context:request.context)}
}
private actor F19InfoTransport:HTTPTransport {
    let withLink:Bool
    let originalPath:String?
    var count=0
    init(withLink:Bool,originalPath:String?=nil){self.withLink=withLink;self.originalPath=originalPath}
    func send(request:HTTPRequest)throws->HTTPResponse {
        count+=1
        let path=originalPath ?? "/fullimg.php?gid=42&amp;page=1&amp;key=synthetic"
        let link=withLink ? "<a href='\(path)'>Download original</a>" : ""
        let body="<html><body><div id='i2'><div class='sn'><div><span>1</span><span>1</span></div></div></div><div id='i3'><img id='img' src='https://media.example.invalid/display.jpg'></div><div id='i5'><div><a href='/g/42/synthetic/'>Gallery</a></div></div>"+link+"</body></html>"
        return try HTTPResponse(requestID:request.id,scope:request.scope,status:200,headers:["Content-Type":"text/html"],body:Data(body.utf8),finalURL:request.url)
    }
}
private actor F19FileTransport:HTTPTransport {
    var requests:[HTTPRequest]=[]
    func send(request:HTTPRequest)throws->HTTPResponse {
        requests.append(request)
        return try HTTPResponse(requestID:request.id,scope:request.scope,status:200,headers:["Content-Type":"image/png"],body:Data("valid-original".utf8),finalURL:request.url)
    }
    func sent()->[HTTPRequest]{requests}
}
@MainActor final class F19OriginalServiceTests:XCTestCase {
    func testOriginalOnlyUsesPageSuppliedLinkAndNeverDisplayCache() async throws {
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1),provider=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        let reference=GalleryReference(key:GalleryKey(site:.ex,galleryID:try GalleryID(42)),token:try SensitiveText("synthetic"))
        let info=F19InfoTransport(withLink:true),files=F19FileTransport(),policy=NetworkPolicy(parsing:ParsingPolicy(ehHost:"eh.example.invalid",exHost:"ex.example.invalid"))
        let service=OriginalImageDownloadService(client:HTTPClient(transport:info,policy:policy),sessions:provider,transport:files)
        let document=ReaderDocument(reference:reference,scope:scope,repository:F19ReaderRepository(reference:reference))
        let data=try await service.load(document:document,index:PageIndex(0),transferID:UUID())
        XCTAssertEqual(data,Data("valid-original".utf8))
        let sent=await files.sent();XCTAssertEqual(sent.count,1);XCTAssertEqual(sent.first?.url.path,"/fullimg.php");XCTAssertEqual(sent.first?.headers,["Accept":"image/*"])
    }
    func testNoSeparateOriginalLinkUsesCurrentPageButLocalOnlyNeverRequestsAnotherFile() async throws {
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1),provider=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        let reference=GalleryReference(key:GalleryKey(site:.ex,galleryID:try GalleryID(42)),token:try SensitiveText("synthetic"))
        let info=F19InfoTransport(withLink:false),files=F19FileTransport(),policy=NetworkPolicy(parsing:ParsingPolicy(ehHost:"eh.example.invalid",exHost:"ex.example.invalid"))
        let service=OriginalImageDownloadService(client:HTTPClient(transport:info,policy:policy),sessions:provider,transport:files),document=ReaderDocument(reference:reference,scope:scope,repository:F19ReaderRepository(reference:reference))
        let data=try await service.load(document:document,index:PageIndex(0),transferID:UUID());XCTAssertEqual(data,Data("valid-original".utf8))
        await provider.update(SessionState(scope:scope,authentication:.authenticated,permitsNetwork:false))
        do {_=try await service.load(document:document,index:PageIndex(0),transferID:UUID());XCTFail()}catch {XCTAssertEqual(error as? AppError,.authenticationRequired)}
        let sent=await files.sent();XCTAssertEqual(sent.count,1);XCTAssertEqual(sent.first?.url.path,"/display.jpg")
    }
}

extension F19OriginalServiceTests {
    func testRewrittenAndDirectOriginalEntriesAreUsedInsteadOfPageImage() async throws {
        for path in ["/fullimg/42/1/synthetic/original.png","https://media.example.invalid/original.png"] {
            let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1),provider=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
            let reference=GalleryReference(key:GalleryKey(site:.ex,galleryID:try GalleryID(42)),token:try SensitiveText("synthetic"))
            let info=F19InfoTransport(withLink:true,originalPath:path),files=F19FileTransport(),policy=NetworkPolicy(parsing:ParsingPolicy(ehHost:"eh.example.invalid",exHost:"ex.example.invalid"))
            let service=OriginalImageDownloadService(client:HTTPClient(transport:info,policy:policy),sessions:provider,transport:files)
            let document=ReaderDocument(reference:reference,scope:scope,repository:F19ReaderRepository(reference:reference))
            _=try await service.load(document:document,index:PageIndex(0),transferID:UUID())
            let sent=await files.sent();XCTAssertEqual(sent.count,1);XCTAssertEqual(sent.first?.url.lastPathComponent,"original.png")
        }
    }
}
