import Foundation
import XCTest
import ErosCore

extension ImageParsingTests {
    func testNoSeparateOriginalLinkUsesCurrentPageOriginalWithUnknownQuota() throws {
        let info = try OriginalImageInfoParser(policy: policy).parse(response("image-bootstrap"), request: request())
        XCTAssertEqual(info.availability, .pageOriginal); XCTAssertEqual(info.permission, .unknown)
        XCTAssertEqual(info.quota, .unknown); XCTAssertEqual(info.feeDescription, "未知")
        XCTAssertEqual(try info.requireLink().path, "/image.jpg")
    }
    func testOriginalExplicitLabelDoesNotInheritDisplaySizeOrGuessCost() throws {
        let base = String(decoding: try file("HTML/image-bootstrap.html"), as: UTF8.self)
        let body = base.replacingOccurrences(of: "</body>", with: "<a href='/fullimg.php?gid=42&amp;page=1&amp;key=synthetic'>Download original 3000 x 4000 4.2 MB</a></body>")
        let parsed = try ImagePageParser(policy: policy).parse(response("image-bootstrap", body: Data(body.utf8)), request: request(), resolvedAt: .distantPast)
        XCTAssertEqual(parsed.originalInfo.availability, .offered)
        XCTAssertEqual(parsed.originalInfo.dimensions, try PixelSize(width: 3000, height: 4000))
        XCTAssertEqual(parsed.originalInfo.sizeLabel, "4.2 MB"); XCTAssertEqual(parsed.originalInfo.quota, .unknown)
        XCTAssertEqual(parsed.originalInfo.pageCostDescription, "未知")
    }
    func testUnsafeAmbiguousOriginalEntryCannotBreakDisplayParsingOrAuthorizeTransfer() throws {
        let base = String(decoding: try file("HTML/image-bootstrap.html"), as: UTF8.self)
        for href in ["https://evil.invalid/fullimg.php?gid=42&page=1", "/fullimg.php?gid=43&page=1", "/fullimg.php?gid=42&page=1&gid=42", "/fullimg.php?gid=42&page=1#secret", "/fullimg.php?gid=42&page=oops", "/fullimg.php?gid=42&page=1&redirect=evil"] {
            let body=base.replacingOccurrences(of: "</body>", with: "<a href='\(href)'>Original</a></body>")
            let parsed=try ImagePageParser(policy: policy).parse(response("image-bootstrap",body:Data(body.utf8)),request:request(),resolvedAt:.distantPast)
            XCTAssertEqual(parsed.originalInfo.availability,.unrecognized);XCTAssertNil(parsed.originalURL)
        }
    }
    func testOriginalInfoRejectsQuotaPage() throws {
        let base = String(decoding: try file("HTML/image-bootstrap.html"), as: UTF8.self).replacingOccurrences(of: "image.jpg", with: "509.gif")
        XCTAssertThrowsError(try OriginalImageInfoParser(policy: policy).parse(response("image-bootstrap", body: Data(base.utf8)), request: request())) { XCTAssertEqual($0 as? AppError, .quotaExceeded) }
    }
}

extension ImageParsingTests {
    func testOriginalMetadataRejectsNeighborPageRatherThanDownloadingWrongOriginal() throws {
        let base=String(decoding:try file("HTML/image-bootstrap.html"),as:UTF8.self)
        let modified=base.replacingOccurrences(of:"<span>1</span>",with:"<span>2</span>")
        XCTAssertNotEqual(modified,base)
        XCTAssertThrowsError(try OriginalImageInfoParser(policy:policy).parse(response("image-bootstrap",body:Data(modified.utf8)),request:request())) {
            XCTAssertEqual($0 as? AppError,.parseMismatch)
        }
    }
}

extension ImageParsingTests {
    func testRewrittenOriginalEndpointsOnEHAndEXAreParsedWithoutChangingParameters() throws {
        for site in [Site.eh,.ex] {
            let current=SessionScope(storage:StorageScope(accountID:scope.storage.accountID,site:site),generation:1)
            let ref=GalleryReference(key:GalleryKey(site:site,galleryID:try GalleryID(42)),token:try SensitiveText("synthetictoken"))
            let pageURL=URL(string:"https://\(site.rawValue).example.invalid/s/syntheticimage/42-1")!
            let req=try ImageResolutionRequest(page:ReaderPage(reference:ref,index:PageIndex(0),pageURL:pageURL),scope:current,reason:.initial)
            let base=String(decoding:try file("HTML/image-bootstrap.html"),as:UTF8.self).replacingOccurrences(of:"eh.example.invalid",with:"\(site.rawValue).example.invalid")
            let body=base.replacingOccurrences(of:"</body>",with:"<a href='/fullimg/42/1/synthetic-key/image%20name.jpg'>Download original 3000 x 4000 4.2 MiB</a></body>")
            let r=try HTTPResponse(requestID:UUID(),scope:current,status:200,headers:["Content-Type":"text/html"],body:Data(body.utf8),finalURL:pageURL)
            let info=try OriginalImageInfoParser(policy:policy).parse(r,request:req)
            XCTAssertEqual(info.availability,.offered);XCTAssertTrue(try info.requireLink().absoluteString.hasSuffix("/fullimg/42/1/synthetic-key/image%20name.jpg"));XCTAssertEqual(info.dimensions,try PixelSize(width:3000,height:4000))
        }
    }
    func testOriginalLabelSupportsDirectMediaAndDoesNotPreferDisplayImage() throws {
        let base=String(decoding:try file("HTML/image-bootstrap.html"),as:UTF8.self)
        let body=base.replacingOccurrences(of:"</body>",with:"<div id='i7'><a href='https://media.example.invalid/original.png'>Download original 3000 x 4000 4.2 MiB</a></div></body>")
        let parsed=try ImagePageParser(policy:policy).parse(response("image-bootstrap",body:Data(body.utf8)),request:request(),resolvedAt:.distantPast)
        XCTAssertEqual(parsed.originalInfo.availability,.offered);XCTAssertEqual(parsed.originalURL?.path,"/original.png");XCTAssertNotEqual(parsed.originalURL,parsed.image.url)
    }
    func testMalformedRewrittenOriginalCannotBecomePageOriginal() throws {
        let base=String(decoding:try file("HTML/image-bootstrap.html"),as:UTF8.self)
        for path in ["/fullimg/43/1/key/image.jpg","/fullimg/42/no/key/image.jpg","/fullimg/42/1//image.jpg","/fullimg/42/1/key/","/fullimg/42/1/key/image.jpg?other=1","https://evil.invalid/fullimg/42/1/key/image.jpg"] {
            let body=base.replacingOccurrences(of:"</body>",with:"<a href='\(path)'>Download original 3000 x 4000</a></body>")
            let parsed=try ImagePageParser(policy:policy).parse(response("image-bootstrap",body:Data(body.utf8)),request:request(),resolvedAt:.distantPast)
            XCTAssertEqual(parsed.originalInfo.availability,.unrecognized);XCTAssertThrowsError(try parsed.originalInfo.requireLink())
        }
    }
    func testShowpageUsesSameRewrittenAndPageOriginalSelectionRules() throws {
        let normal=try ShowPageParser(policy:policy).parse(response("showpage-success"),request:request(1),resolvedAt:.distantPast)
        XCTAssertEqual(normal.originalInfo.availability,.pageOriginal);XCTAssertEqual(try normal.originalInfo.requireLink(),normal.image.url)
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:file("JSON/showpage-success.json")) as? [String:Any])
        object["i6"]="<a href='/fullimg/42/2/synthetic/original.png'>Download original 3000 x 4000 4.2 MiB</a>"
        let result=try ShowPageParser(policy:policy).parse(response("showpage-success",body:JSONSerialization.data(withJSONObject:object)),request:request(1),resolvedAt:.distantPast)
        XCTAssertEqual(result.originalInfo.availability,.offered);XCTAssertEqual(result.originalURL?.path,"/fullimg/42/2/synthetic/original.png")
    }
}
