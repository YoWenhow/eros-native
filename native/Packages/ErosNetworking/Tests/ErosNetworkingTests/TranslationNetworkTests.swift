import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import ErosCore
@testable import ErosNetworking

private final class TranslationProtocol:URLProtocol,@unchecked Sendable {
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        XCTAssertNil(request.value(forHTTPHeaderField:"Cookie"));XCTAssertNil(request.value(forHTTPHeaderField:"Authorization"))
        let response=HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:[:])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(repeating:65,count:64));client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class TranslationNetworkTests:XCTestCase,@unchecked Sendable {
    func testPublicAddressPolicy() {
        XCTAssertTrue(TranslationHTTPFetcher.permits(URL(string:"https://api.github.com/repos/EhTagTranslation/Database/releases/latest")!))
        XCTAssertTrue(TranslationHTTPFetcher.permits(URL(string:"https://release-assets.githubusercontent.com/asset?signature=x")!,redirect:true))
        for url in ["http://github.com/x","https://evil.invalid/x","https://user:pass@release-assets.githubusercontent.com/x","https://api.github.com/repos/other/repo/releases/latest","https://github.com/EhTagTranslation/Database/releases/latest/download/db.text.json"] {
            XCTAssertFalse(TranslationHTTPFetcher.permits(URL(string:url)!));XCTAssertFalse(TranslationHTTPFetcher.permits(URL(string:url)!,redirect:true))
        }
    }
    func testUnknownLengthResponseIsBoundedAndCredentialFree() async throws {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[TranslationProtocol.self]
        let fetcher=TranslationHTTPFetcher(configuration:config),url=URL(string:"https://api.github.com/repos/EhTagTranslation/Database/releases/latest")!
        do{_ = try await fetcher.fetch(url,maximumBytes:32);XCTFail()}catch{}
        let result=try await fetcher.fetch(url,maximumBytes:64);XCTAssertEqual(result.count,64)
    }
}
