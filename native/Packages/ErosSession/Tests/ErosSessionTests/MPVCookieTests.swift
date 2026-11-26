import Foundation
import XCTest
import ErosCore
@testable import ErosSession

extension SessionTests {
    func testMPVCookiesRequireDomainBindingAndExactAPIPath() throws {
        let api = URL(string:"https://api.e-hentai.org/api.php")!
        let domain = try SessionCookie(name:"synthetic",value:"secret",domain:"e-hentai.org",hostOnly:false)
        XCTAssertTrue(domain.matches(api,now:Date()))
        XCTAssertFalse(try cookie().matches(api,now:Date()))
        for url in ["https://s.exhentai.org/api.php","https://api.e-hentai.org/image.jpg","https://api.e-hentai.org/api.php?x=1","http://api.e-hentai.org/api.php"] { XCTAssertFalse(domain.matches(URL(string:url)!,now:Date())) }
    }
    func testMPVSessionDoesNotLeakToMediaOrOtherSite() async throws {
        let manager = try await make(); let guest = try await manager.current()
        try await manager.merge([SessionCookie(name:"ipb_pass_hash",value:"secret",domain:"e-hentai.org",hostOnly:false)],scope:guest.scope)
        try await manager.verify(using:Verifier(result:.authenticated(subject:"synthetic-member")))
        let scope = try await manager.current().scope
        let accepted = try await manager.cookieHeader(url:URL(string:"https://api.e-hentai.org/api.php")!,scope:scope)
        XCTAssertNotNil(accepted)
        for url in ["https://s.exhentai.org/api.php","https://api.e-hentai.org/image.jpg"] {
            let value = try await manager.cookieHeader(url:URL(string:url)!,scope:scope); XCTAssertNil(value)
        }
    }
}
