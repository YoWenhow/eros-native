import Foundation
import XCTest
import ErosCore
@testable import ErosNetworking

private actor OriginalCredentials: RequestCredentials {
    var active:Set<UUID>=[]
    var headerHosts:[String]=[]
    var receivedHosts:[String]=[]
    func register(id:UUID,scope:SessionScope,cancel:@escaping @Sendable ()->Void) { active.insert(id) }
    func unregister(id:UUID) {active.remove(id)}
    func cookieHeader(url:URL,scope:SessionScope)->String? {headerHosts.append(url.host!);return "synthetic=secret"}
    func receive(headers:[String:String],url:URL,scope:SessionScope) {receivedHosts.append(url.host!)}
    func counts()->(Int,[String],[String]) {(active.count,headerHosts,receivedHosts)}
}
private actor OriginalHops {
    var requests:[HTTPRequest]=[]
    let responses:[(Int,[String:String],Data)]
    let failure:AppError?
    init(_ responses:[(Int,[String:String],Data)],failure:AppError?=nil){self.responses=responses;self.failure=failure}
    func send(_ request:HTTPRequest)throws->HTTPResponse {
        requests.append(request)
        if let failure {throw failure}
        let i=requests.count-1;guard i<responses.count else {throw AppError.invalidInput}
        let r=responses[i]
        return try HTTPResponse(requestID:request.id,scope:request.scope,status:r.0,headers:r.1,body:r.2,finalURL:request.url)
    }
    func sent()->[HTTPRequest] {requests}
}
@MainActor final class F19OriginalTransportTests:XCTestCase {
    let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1)
    let policy=NetworkPolicy(parsing:ParsingPolicy(ehHost:"eh.example.invalid",exHost:"ex.example.invalid"),mediaHosts:["media.example.invalid"],allowOriginalImageRequests:true)
    func request()->HTTPRequest {HTTPRequest(id:UUID(),scope:scope,url:URL(string:"https://ex.example.invalid/fullimg.php?gid=42&page=1&key=synthetic")!,method:.get,headers:["Accept":"image/*"])}
    func testOriginalChainCredentialsOnlyAtAccountHopAndUnregisters() async throws {
        let credentials=OriginalCredentials(),hops=OriginalHops([(302,["Location":"https://media.example.invalid/original.png"],Data()),(200,["Content-Type":"image/png"],Data([137,80,78,71]))])
        let transport=OriginalImageTransport(network:policy,credentials:credentials,hop:{try await hops.send($0)})
        let response=try await transport.send(request:request());XCTAssertEqual(response.body,Data([137,80,78,71]))
        let sent=await hops.sent();XCTAssertEqual(sent.count,2);XCTAssertEqual(sent[0].headers["Cookie"],"synthetic=secret");XCTAssertNil(sent[1].headers["Cookie"])
        let c=await credentials.counts();XCTAssertEqual(c.0,0);XCTAssertEqual(c.1,["ex.example.invalid"]);XCTAssertEqual(c.2,["ex.example.invalid"])
    }
    func testQuotaRateLimitTimeoutAndHTMLNeverAutomaticallyRetry() async throws {
        for (status,headers,body,expected) in [(509,["Content-Type":"text/html"],Data("limit".utf8),AppError.quotaExceeded),(429,["Content-Type":"text/html"],Data(),AppError.rateLimited(retryAfter:nil)),(200,["Content-Type":"image/jpeg"],Data("<html>quota</html>".utf8),AppError.unsupportedContent)] {
            let credentials=OriginalCredentials(),hops=OriginalHops([(status,headers,body)])
            let transport=OriginalImageTransport(network:policy,credentials:credentials,hop:{try await hops.send($0)})
            do {_=try await transport.send(request:request());XCTFail()}catch {XCTAssertEqual(error as? AppError,expected)}
            let count=await hops.sent().count;XCTAssertEqual(count,1)
            let c=await credentials.counts();XCTAssertEqual(c.0,0)
        }
        let hops=OriginalHops([],failure:.transport(code:-1001)),transport=OriginalImageTransport(network:policy,credentials:nil,hop:{try await hops.send($0)})
        do {_=try await transport.send(request:request());XCTFail()}catch {XCTAssertEqual(error as? AppError,.transport(code:-1001))}
        let count=await hops.sent().count;XCTAssertEqual(count,1)
    }
    func testUntrustedRedirectAndMediaBounceNeverSendCredentialsOrRequest() async throws {
        for location in ["https://evil.invalid/orig.jpg","http://media.example.invalid/orig.jpg","https://eh.example.invalid/fullimg.php"] {
            let hops=OriginalHops([(302,["Location":location],Data())])
            let transport=OriginalImageTransport(network:policy,credentials:nil,hop:{try await hops.send($0)})
            do {_=try await transport.send(request:request());XCTFail()}catch {XCTAssertEqual(error as? AppError,.accessDenied)}
            let count=await hops.sent().count;XCTAssertEqual(count,1)
        }
        let credentials=OriginalCredentials(),hops=OriginalHops([(302,["Location":"https://media.example.invalid/i.jpg"],Data()),(302,["Location":"https://ex.example.invalid/fullimg.php"],Data())])
        let transport=OriginalImageTransport(network:policy,credentials:credentials,hop:{try await hops.send($0)})
        do {_=try await transport.send(request:request());XCTFail()}catch {XCTAssertEqual(error as? AppError,.accessDenied)}
        let sent=await hops.sent();XCTAssertEqual(sent.count,2);XCTAssertNil(sent[1].headers["Cookie"])
    }
    func testOriginalFileCapChecksActualBodyAsWellAsDeclaredSize() async throws {
        for (headers,bytes) in [(["Content-Type":"image/jpeg","Content-Length":"999999999"],Data([1])),(["Content-Type":"image/jpeg"],Data(repeating:1,count:OriginalImageTransferPolicy.maximumBytes+1))] {
            let hops=OriginalHops([(200,headers,bytes)]),transport=OriginalImageTransport(network:policy,credentials:nil,hop:{try await hops.send($0)})
            do {_=try await transport.send(request:request());XCTFail()}catch {XCTAssertEqual(error as? AppError,.unsupportedContent)}
            let count=await hops.sent().count;XCTAssertEqual(count,1)
        }
    }
}

extension F19OriginalTransportTests {
    func testRewrittenOriginalEntryUsesSiteCredentialsThenStripsThemFromMedia() async throws {
        let credentials=OriginalCredentials(),hops=OriginalHops([(302,["Location":"https://media.example.invalid/original.jpg"],Data()),(200,["Content-Type":"image/jpeg"],Data([255,216,255]))])
        let transport=OriginalImageTransport(network:policy,credentials:credentials,hop:{try await hops.send($0)})
        let request=HTTPRequest(id:UUID(),scope:scope,url:URL(string:"https://ex.example.invalid/fullimg/42/1/synthetic/original.jpg")!,method:.get,headers:["Accept":"image/*"])
        _=try await transport.send(request:request)
        let sent=await hops.sent();XCTAssertEqual(sent.count,2);XCTAssertNotNil(sent[0].headers["Cookie"]);XCTAssertNil(sent[1].headers["Cookie"])
    }
    func testDirectOriginalStartsAtTrustedMediaWithoutCookieOrSiteProbe() async throws {
        let credentials=OriginalCredentials(),hops=OriginalHops([(200,["Content-Type":"image/jpeg"],Data([255,216,255]))])
        let transport=OriginalImageTransport(network:policy,credentials:credentials,hop:{try await hops.send($0)})
        let request=HTTPRequest(id:UUID(),scope:scope,url:URL(string:"https://media.example.invalid/original.jpg")!,method:.get,headers:["Accept":"image/*"])
        _=try await transport.send(request:request)
        let sent=await hops.sent();XCTAssertEqual(sent.count,1);XCTAssertNil(sent[0].headers["Cookie"])
        let c=await credentials.counts();XCTAssertTrue(c.1.isEmpty);XCTAssertTrue(c.2.isEmpty)
    }
    func testDefaultDisplayNetworkAlsoRejectsRewrittenFullimgPaths() throws {
        let normal=NetworkPolicy(parsing:policy.parsing)
        XCTAssertThrowsError(try normal.validate(URL(string:"https://ex.example.invalid/fullimg/42/1/key/original.jpg")!,scope:scope))
        XCTAssertThrowsError(try normal.validate(URL(string:"https://ex.example.invalid/fullimg.php?gid=42&page=1")!,scope:scope))
    }
}
