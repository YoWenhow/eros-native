import Foundation
import Testing
import ErosCore

struct ArchivePreparationTests {
    let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1)
    let path="/archive/42/0123456789012345678901234567890123456789/synthetic/2"
    var url:URL { URL(string:"https://abcdefghijklmnopqrst.hath.network"+path)! }
    func address() throws -> ArchivePreparationAddress { try ArchivePreparationAddress(url:url,gallery:GalleryID(42)) }
    func html(link:String?=nil)->String { "<html><body><div id='db'><p>The file was successfully prepared, and is ready for download.<br><strong>synthetic.zip</strong><br><a href='\(link ?? (path+"?start=1"))'>Click Here To Start Downloading</a><br>You can also copy this link to a download manager.</p></div></body></html>" }
    func parse(_ html:String,alterScope:Bool=false) throws -> PreparedArchive {
        let address=try address(),request=address.request(scope:scope)
        let response=try HTTPResponse(requestID:request.id,scope:alterScope ? scope.advanced() : scope,status:200,headers:["Content-Type":"text/html"],body:Data(html.utf8),finalURL:url)
        return try ArchivePreparationParser().parse(response,request:request,address:address)
    }
    @Test func observedReadyPageUsesExactReturnedLink() throws {
        let ready=try parse(html())
        #expect(ready.downloadURL.path==path)
        #expect(ready.downloadURL.query=="start=1")
        #expect(!String(describing:ready).contains("synthetic"))
        #expect(!String(reflecting:ready.address).contains("hath.network"))
    }
    @Test func preparationAddressNeverAcceptsFileQueryWrongGalleryOrForeignHost() throws {
        for candidate in [url.absoluteString+"?start=1",url.absoluteString.replacingOccurrences(of:"/42/",with:"/43/"),url.absoluteString.replacingOccurrences(of:".hath.network",with:".hath.network.evil.invalid"),url.absoluteString.replacingOccurrences(of:"https:",with:"http:"),url.absoluteString+"#token",url.absoluteString.replacingOccurrences(of:"/synthetic/",with:"/synthetic%2F/" )] {
            #expect(throws:AppError.accessDenied) { _=try ArchivePreparationAddress(url:URL(string:candidate)!,gallery:GalleryID(42)) }
        }
    }
    @Test func crossHostChangedPathAndRepeatedStartRejected() throws {
        for link in ["https://evil.invalid"+path+"?start=1",path+"?start=1&start=1",path+"?start=2",path.replacingOccurrences(of:"synthetic",with:"another")+"?start=1",path+"?start=1#fragment"] {
            #expect(throws:AppError.parseMismatch) { _=try parse(html(link:link)) }
        }
    }
    @Test func unknownPageNotMistakenForWaitingOrReady() throws {
        #expect(throws:AppError.parseMismatch) { _=try parse("<html><body><div id='db'><p>Unknown preparation state</p></div></body></html>") }
        #expect(throws:AppError.parseMismatch) { _=try parse(html().replacingOccurrences(of:"The file was successfully prepared, and is ready for download.",with:"Access denied")) }
    }
    @Test func oldSessionResponseCannotBecomeReady() throws {
        #expect(throws:AppError.staleSession) { _=try parse(html(),alterScope:true) }
    }
}
