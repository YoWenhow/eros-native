import Foundation
import Testing
import ErosCore
@testable import ErosNetworking

private actor ArchiveHop {
 var requests:[HTTPRequest]=[]
 let status:Int
 let bytes:Data
 init(status:Int=200,bytes:Data=Data("<html>ready</html>".utf8)) { self.status=status;self.bytes=bytes }
 func send(_ request:HTTPRequest) throws -> HTTPResponse {
  requests.append(request)
  return try HTTPResponse(requestID:request.id,scope:request.scope,status:status,headers:["Content-Type":"text/html","Location":"https://evil.invalid/","Retry-After":"120"],body:bytes,finalURL:request.url)
 }
 func count()->Int { requests.count }
}
struct ArchivePreparationTransportTests {
 let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1)
 func address() throws -> ArchivePreparationAddress { try ArchivePreparationAddress(url:URL(string:"https://abcdefghijklmnopqrst.hath.network/archive/42/0123456789012345678901234567890123456789/synthetic/2")!,gallery:GalleryID(42)) }
 @Test func headersAreStrictlyCredentialFree() async throws {
  let address=try address(),hop=ArchiveHop()
  let transport=ArchivePreparationTransport(address:address,hop:{try await hop.send($0)})
  let good=address.request(scope:scope)
  for header in ["Cookie","Authorization","Referer"] {
   let bad=HTTPRequest(id:UUID(),scope:scope,url:good.url,method:.get,headers:["Accept":"text/html",header:"synthetic"])
   await #expect(throws:AppError.accessDenied) { _=try await transport.send(request:bad) }
  }
  #expect(await hop.count()==0)
  _=try await transport.send(request:good)
  #expect(await hop.count()==1)
 }
 @Test func redirectNeverFollowedAndRateLimitNotRetried() async throws {
  let address=try address()
  for status in [302,429] {
   let hop=ArchiveHop(status:status),request=address.request(scope:scope)
   let transport=ArchivePreparationTransport(address:address,hop:{try await hop.send($0)})
   await #expect(throws:(any Error).self) { _=try await transport.send(request:request) }
   #expect(await hop.count()==1)
  }
 }
 @Test func cannotFetchFileOrPost() async throws {
  let address=try address(),hop=ArchiveHop()
  let transport=ArchivePreparationTransport(address:address,hop:{try await hop.send($0)})
  for request in [HTTPRequest(id:UUID(),scope:scope,url:URL(string:address.url.absoluteString+"?start=1")!,method:.get,headers:["Accept":"text/html"]),HTTPRequest(id:UUID(),scope:scope,url:address.url,method:.post,headers:["Accept":"text/html"])] {
   await #expect(throws:AppError.accessDenied) { _=try await transport.send(request:request) }
  }
  #expect(await hop.count()==0)
 }
 @Test func oversizedResponseRejected() async throws {
  let address=try address(),hop=ArchiveHop(bytes:Data(repeating:0,count:ArchivePreparationTransport.maximumBytes+1))
  let transport=ArchivePreparationTransport(address:address,hop:{try await hop.send($0)})
  await #expect(throws:AppError.unsupportedContent) { _=try await transport.send(request:address.request(scope:scope)) }
 }
}
