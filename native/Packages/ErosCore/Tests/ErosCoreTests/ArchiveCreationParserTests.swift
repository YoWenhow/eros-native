import Foundation
import Testing
import ErosCore

struct ArchiveCreationParserTests {
    let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1)
    let peer="https://abcdefghijklmnopqrst.hath.network/archive/42/0123456789012345678901234567890123456789/synthetic/2"
    var action: URL { URL(string:"https://ex.example.invalid/archiver.php?gid=42&token=synthetic")! }
    var html:String { """
    <html><body><div id="db"><p>Locating archive server and preparing file for download...</p>
    <p>(this can take several minutes)</p>
    <p id="continue">(<a href="\(peer)" onclick="gotonext(); return false">Click here if your browser does not continue automatically</a>)</p>
    <script>function gotonext() { document.location = "\(peer)"; } setTimeout("gotonext()", 1);</script>
    </div></body></html>
    """ }
    func parse(_ body:String,changedScope:Bool=false) throws -> ArchiveCreationReceipt {
        let request=try GalleryRequest(reference:GalleryReference(key:GalleryKey(site:.ex,galleryID:GalleryID(42)),token:SensitiveText("synthetic")),scope:scope)
        let submitted=HTTPRequest(id:UUID(),scope:scope,url:action,method:.post,headers:["Accept":"text/html"],body:Data())
        let response=try HTTPResponse(requestID:submitted.id,scope:changedScope ? scope.advanced() : scope,status:200,headers:["Content-Type":"text/html"],body:Data(body.utf8),finalURL:action)
        return try ArchiveCreationParser(policy:ParsingPolicy(ehHost:"eh.example.invalid",exHost:"ex.example.invalid")).parse(response,submission:submitted,request:request)
    }
    @Test func matchedLinkAndScriptGrantOneAddress() throws {
        let receipt=try parse(html)
        #expect(receipt.address.url.absoluteString==peer)
        #expect(!String(describing:receipt).contains("hath.network"))
    }
    @Test func mismatchedOrDuplicateDestinationRejected() throws {
        for body in [html.replacingOccurrences(of:"href=\"\(peer)\"",with:"href=\"https://evil.invalid/archive\""),
                     html.replacingOccurrences(of:"</script>",with:"document.location = \"\(peer)\";</script>"),
                     html.replacingOccurrences(of:"/archive/42/",with:"/archive/43/")] {
            #expect(throws:(any Error).self) { _=try parse(body) }
        }
    }
    @Test func unknownResponseCannotCreateReceipt() throws {
        #expect(throws:AppError.parseMismatch) { _=try parse("<div id='db'><p>Access denied</p></div>") }
        #expect(throws:AppError.staleSession) { _=try parse(html,changedScope:true) }
    }
}
