import Foundation
import Testing
import ErosCore
@testable import ErosServices

@Suite struct BackgroundImageResponseTests {
    @Test func mapsMediaFailuresWithoutTreatingQuotaAsAnExpiredAddress() {
        #expect(BackgroundImageResponse.error(forStatus: 403) == .imageExpired)
        #expect(BackgroundImageResponse.error(forStatus: 401) == .authenticationRequired)
        #expect(BackgroundImageResponse.error(forStatus: 429) == .rateLimited(retryAfter: nil))
        #expect(BackgroundImageResponse.error(forStatus: 509) == .quotaExceeded)
        #expect(BackgroundImageResponse.error(forStatus: 503) == .httpStatus(503))
        #expect(BackgroundImageResponse.error(inTextPrefix: Data("<html>You have exceeded your image viewing limits.</html>".utf8)) == .quotaExceeded)
        #expect(BackgroundImageResponse.error(inTextPrefix: Data("<p>You have reached the image limit and must wait.</p>".utf8)) == .quotaExceeded)
        #expect(BackgroundImageResponse.error(inTextPrefix: Data("<p>Transfer requires GP, and you do not have enough.</p>".utf8)) == .quotaExceeded)
        #expect(BackgroundImageResponse.error(inTextPrefix: Data("<html>Your IP address has been banned.</html>".utf8)) == .accessDenied)
        #expect(BackgroundImageResponse.error(inTextPrefix: Data("<html>Unavailable</html>".utf8)) == nil)
    }

    @Test func repeatedlyInterruptedAddressOrExpiredImageRequestsAnotherNode() {
        let partial = PageDownloadTransferFailure(.transport(code: -1005), receivedBytes: true)
        #expect(PageDownloadRetry.resolution(after: partial, previous: nil) == .retryDownloadAddress)
        #expect(PageDownloadRetry.resolution(after: partial, previous: .retryDownloadAddress) == .retryDownloadSource)
        let empty = PageDownloadTransferFailure(.transport(code: -1001))
        #expect(PageDownloadRetry.resolution(after: empty, previous: nil) == .retryDownloadSource)
        let expired = PageDownloadTransferFailure(.imageExpired, receivedBytes: true)
        #expect(PageDownloadRetry.resolution(after: expired, previous: nil) == .retryDownloadSource)
    }

    @Test func secureConnectionFailureOnlySelectsCandidateForMediaTransfer() {
        let tls = AppError.transport(code: URLError.secureConnectionFailed.rawValue)
        #expect(PageDownloadRetry.resolution(after: tls, previous: nil) == nil)
        for receivedBytes in [false, true] {
            let transfer = PageDownloadTransferFailure(tls, receivedBytes: receivedBytes)
            #expect(PageDownloadRetry.resolution(after: transfer, previous: nil) == .retryDownloadSource)
            #expect(PageDownloadRetry.resolution(after: transfer, previous: .retryDownloadSource) == .retryDownloadSource)
        }
        let untrusted = PageDownloadTransferFailure(.transport(code: URLError.serverCertificateUntrusted.rawValue))
        #expect(PageDownloadRetry.resolution(after: untrusted, previous: nil) == nil)
    }

    @Test func acceptsFullAndAssembledImages() {
        #expect(BackgroundImageResponse.containsCompleteFile(status: 200, contentRange: nil, fileBytes: 196_992))
        #expect(BackgroundImageResponse.containsCompleteFile(
            status: 206, contentRange: "bytes 37376-196991/196992", fileBytes: 196_992
        ))
        #expect(BackgroundImageResponse.containsCompleteFile(
            status: 206, contentRange: " Bytes 0-99/100 ", fileBytes: 100
        ))
    }

    @Test(arguments: [
        ("bytes 37376-196991/196992", 159_616),
        ("bytes 0-99/200", 200),
        ("bytes 10-9/10", 10),
        ("bytes 0-1/*", 2),
        ("bytes -2-1/2", 2),
        ("bytes 0-2/2", 2),
        ("bytes 0-1/18446744073709551616", 2),
        ("bytes 0-1/2, 4-5/8", 2)
    ])
    func rejectsUnassembledOrInvalidRange(contentRange: String, bytes: Int) {
        #expect(!BackgroundImageResponse.containsCompleteFile(
            status: 206, contentRange: contentRange, fileBytes: bytes
        ))
    }

    @Test func rejectsMissingRangeOrUnsupportedStatus() {
        #expect(!BackgroundImageResponse.containsCompleteFile(status: 206, contentRange: nil, fileBytes: 100))
        #expect(!BackgroundImageResponse.containsCompleteFile(status: 416, contentRange: "bytes 0-99/100", fileBytes: 100))
        #expect(!BackgroundImageResponse.containsCompleteFile(status: 200, contentRange: nil, fileBytes: 0))
    }
}
