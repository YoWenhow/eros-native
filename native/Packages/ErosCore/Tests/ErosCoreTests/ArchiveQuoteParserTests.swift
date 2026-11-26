import Foundation
import Testing
import ErosCore

struct ArchiveQuoteParserTests {
    let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1)
    let policy=ParsingPolicy(ehHost:"eh.example.invalid",exHost:"ex.example.invalid")
    var url:URL { URL(string:"https://ex.example.invalid/archiver.php?gid=42&token=synthetic")! }
    var html:String { """
    <html><body><div id="db"><div>
    <div><div>Download Cost: <strong>1,066 GP</strong></div>
    <form method="post" action="https://ex.example.invalid/archiver.php?gid=42&amp;token=synthetic">
    <input type="hidden" name="dltype" value="org"><div><input type="submit" name="dlcheck" value="Download Original Archive"></div></form>
    <p>Estimated Size: <strong>50.83 MiB</strong></p></div>
    <div><div>Download Cost: <strong>269 GP</strong></div>
    <form method="post" action="https://ex.example.invalid/archiver.php?gid=42&amp;token=synthetic">
    <input type="hidden" name="dltype" value="res"><div><input type="submit" name="dlcheck" value="Download Resample Archive"></div></form>
    <p>Estimated Size: <strong>12.80 MiB</strong></p></div></div>
    <div><form method="post"><input type="hidden" name="hathdl_xres" value=""></form></div>
    </div></body></html>
    """ }
    func parse(_ html:String) throws -> [ArchiveOffer] {
        let request=try GalleryRequest(reference:GalleryReference(key:GalleryKey(site:.ex,galleryID:GalleryID(42)),token:SensitiveText("synthetic")),scope:scope)
        let response=try HTTPResponse(requestID:UUID(),scope:scope,status:200,headers:["Content-Type":"text/html"],body:Data(html.utf8),finalURL:url)
        return try ArchiveQuoteParser(policy:policy).parse(response,request:request,now:Date(timeIntervalSince1970:1000))
    }
    @Test func observedFormsMapVariantsPricesAndSizeWithoutHath() throws {
        let offers=try parse(html)
        #expect(offers.count==2)
        #expect(offers[0].variant == .original && offers[1].variant == .display)
        #expect(offers[0].quote.price == .amount(1066,currency:"GP"))
        #expect(offers[1].quote.price == .amount(269,currency:"GP"))
        #expect(offers[0].quote.sizeLabel=="50.83 MiB")
        #expect(offers[0].fields["dltype"]?.value=="org")
    }
    @Test func missingChangedAndDuplicateTypeCannotAuthorize() throws {
        for mutation in [html.replacingOccurrences(of:"value=\"org\"",with:"value=\"unexpected\""),
                         html.replacingOccurrences(of:"value=\"org\"",with:""),
                         html.replacingOccurrences(of:"name=\"dltype\"",with:"name=\"unknown\""),
                         html.replacingOccurrences(of:"value=\"org\"",with:"value=\"res\"")] {
            #expect(throws:AppError.parseMismatch) { _=try parse(mutation) }
        }
    }
    @Test func foreignOrDifferentGalleryFormRejected() throws {
        #expect(throws:(any Error).self) { _=try parse(html.replacingOccurrences(of:"ex.example.invalid",with:"evil.invalid")) }
        #expect(throws:AppError.parseMismatch) { _=try parse(html.replacingOccurrences(of:"gid=42",with:"gid=43")) }
        #expect(throws:AppError.parseMismatch) { _=try parse(html.replacingOccurrences(of:"token=synthetic",with:"token=other")) }
    }
    @Test func unrecognizedPriceRemainsUnknownInsteadOfFree() throws {
        let offers=try parse(html.replacingOccurrences(of:"1,066 GP",with:"Please wait"))
        #expect(offers[0].quote.price == .unknown)
        #expect(ArchiveQuoteParser.price("Free!") == .free)
        #expect(ArchiveQuoteParser.price("1,06 GP") == .unknown)
        #expect(ArchiveQuoteParser.price("0 GP") == .amount(0,currency:"GP"))
        #expect(ArchiveQuoteParser.price("-5 GP") == .unknown)
    }
    @Test func errorOrHathOnlyPageIsNotAnEmptySuccess() throws {
        #expect(throws:AppError.parseMismatch) { _=try parse("<html><body><div id='db'>Denied<form><input name='hathdl_xres'></form></div></body></html>") }
    }
}
