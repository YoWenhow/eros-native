import Foundation
import Testing
import ErosCore
import ErosNetworking
@testable import ErosServices

// Seven-segment origin route with synthetic descriptors, dispatch token and DNS label.
private let origin = "https://abcdefghij.hath.network/om"
private let first = String(repeating: "a", count: 40) + "-1024-320-480-png"
private let second = String(repeating: "b", count: 40) + "-800-320-480-wbp"
let syntheticOriginImage = URL(string: origin + "/42/" + first + "/x/0/syntheticdispatch/image.png")!
let syntheticLongOriginImage = URL(string: syntheticOriginImage.absoluteString.replacingOccurrences(
    of: "abcdefghij.hath.network", with: "abcdefghijklmnopqrst.hath.network"))!

@Suite struct BackgroundImageAdmissionTests {
    private let policy = ImagePipeline.productionPolicy
    private let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .ex), generation: 3)

    private func resolved(_ url: URL, usedReload: Bool, index: PageIndex) throws -> BackgroundImageResolution {
        let reference = GalleryReference(key: GalleryKey(site: .ex, galleryID: try GalleryID(42)),
            token: try SensitiveText("synthetic"))
        let page = ReaderPage(reference: reference, index: index, pageURL: URL(string: "https://exhentai.org/s/synthetic/42-2")!)
        return BackgroundImageResolution(image: try ResolvedImage(page: page, scope: scope, url: url, resolvedAt: .distantPast),
            receivedFromReloadPage: usedReload)
    }

    @Test func originFormatRequiresAnActualReloadPageResult() throws {
        let index = try PageIndex(1)
        let ticket = BackgroundTransferTicket(jobID: UUID(), generation: 21, index: index, storage: scope.storage)
        let resample = URL(string: origin + "/42/" + first + "/" + second + "/320/syntheticdispatch/image.webp")!
        for url in [syntheticOriginImage, syntheticLongOriginImage, resample] {
            let ordinary = try resolved(url, usedReload: false, index: index)
            let fromReload = try resolved(url, usedReload: true, index: index)
            #expect(throws: AppError.accessDenied) { try BackgroundImageAdmission(resolution: ordinary, ticket: ticket, policy: policy) }
            #expect(throws: AppError.accessDenied) { try policy.validate(url, scope: scope, allowMedia: true) }
            let admission = try BackgroundImageAdmission(resolution: fromReload, ticket: ticket, policy: policy)
            #expect(admission.reloadImageSHA256?.count == 64)
        }
        let otherIndex = try PageIndex(2)
        let wrongPage = try resolved(syntheticOriginImage, usedReload: true, index: otherIndex)
        #expect(throws: AppError.scopeMismatch) { try BackgroundImageAdmission(resolution: wrongPage, ticket: ticket, policy: policy) }
        let foreign = BackgroundTransferTicket(jobID: ticket.jobID, generation: ticket.generation, index: index,
            storage: StorageScope(accountID: AccountID(UUID()), site: .ex))
        let reload = try resolved(syntheticOriginImage, usedReload: true, index: index)
        #expect(throws: AppError.scopeMismatch) { try BackgroundImageAdmission(resolution: reload, ticket: foreign, policy: policy) }
    }

    @Test func rejectsUnrelatedHostsPortsAndMalformedPathsFromReload() throws {
        let index = try PageIndex(1)
        let ticket = BackgroundTransferTicket(jobID: UUID(), generation: 21, index: index, storage: scope.storage)
        let valid = syntheticOriginImage.absoluteString
        let unsafe = [
            valid.replacingOccurrences(of: "https:", with: "http:"),
            valid.replacingOccurrences(of: "abcdefghij.hath.network", with: "abcdefghijklmnopqrs.hath.network"),
            valid.replacingOccurrences(of: "abcdefghij.hath.network", with: "abcdefghijklmnopqrstu.hath.network"),
            valid.replacingOccurrences(of: "abcdefghij.hath.network", with: "abcdefghij.klmnopqrst.hath.network"),
            valid.replacingOccurrences(of: "abcdefghij.hath.network", with: "abcdefghij.hath.network.other.invalid"),
            valid.replacingOccurrences(of: "abcdefghij.hath.network", with: "abcdefghij.hath.network:6968"),
            valid.replacingOccurrences(of: "/om/", with: "/unknown/"),
            valid.replacingOccurrences(of: first, with: "bogus"),
            valid.replacingOccurrences(of: "/x/0/", with: "/x/320/"),
            valid.replacingOccurrences(of: "/image.png", with: "/%2Fimage.png"),
            valid.replacingOccurrences(of: "/image.png", with: "/%2E%2E"),
            valid + "?query=synthetic",
            valid + "#fragment",
            valid.replacingOccurrences(of: "https://", with: "https://synthetic@"),
        ]
        for value in unsafe {
            let url = try #require(URL(string: value))
            let fromReload = try resolved(url, usedReload: true, index: index)
            #expect(throws: AppError.accessDenied) {
                try BackgroundImageAdmission(resolution: fromReload, ticket: ticket, policy: policy)
            }
        }
    }

    @Test func restoredReceiptRechecksExactAddressPageAndGeneration() throws {
        let index = try PageIndex(1)
        let ticket = BackgroundTransferTicket(jobID: UUID(), generation: 21, index: index, storage: scope.storage)
        let resolution = try resolved(syntheticOriginImage, usedReload: true, index: index)
        let admission = try BackgroundImageAdmission(resolution: resolution, ticket: ticket, policy: policy)
        let record = BackgroundDownloadInbox.Record(ticket: ticket, site: .ex, taskID: 7, complete: false,
            errorCode: nil, reloadImageSHA256: admission.reloadImageSHA256)
        let data = try JSONEncoder().encode(record)
        #expect(!String(decoding: data, as: UTF8.self).contains("syntheticdispatch"))
        let restored = try JSONDecoder().decode(BackgroundDownloadInbox.Record.self, from: data)
        try BackgroundImageAdmission.validateResponse(syntheticOriginImage, record: restored, policy: policy)

        let otherURL = URL(string: syntheticOriginImage.absoluteString.replacingOccurrences(of: "image.png", with: "other.png"))!
        #expect(throws: AppError.accessDenied) {
            try BackgroundImageAdmission.validateResponse(otherURL, record: restored, policy: policy)
        }
        let stale = BackgroundTransferTicket(jobID: ticket.jobID, generation: ticket.generation + 1, index: index, storage: scope.storage)
        let otherPage = BackgroundTransferTicket(jobID: ticket.jobID, generation: ticket.generation, index: try PageIndex(2), storage: scope.storage)
        for different in [stale, otherPage] {
            let rebound = BackgroundDownloadInbox.Record(ticket: different, site: .ex, taskID: 7,
                complete: false, errorCode: nil, reloadImageSHA256: restored.reloadImageSHA256)
            #expect(throws: AppError.accessDenied) {
                try BackgroundImageAdmission.validateResponse(syntheticOriginImage, record: rebound, policy: policy)
            }
        }

        let legacy = BackgroundDownloadInbox.Record(ticket: ticket, site: .ex, taskID: 8, complete: false, errorCode: nil)
        let legacyData = try JSONEncoder().encode(legacy)
        #expect(!String(decoding: legacyData, as: UTF8.self).contains("reloadImageSHA256"))
        let old = try JSONDecoder().decode(BackgroundDownloadInbox.Record.self, from: legacyData)
        try BackgroundImageAdmission.validateResponse(
            URL(string: "https://synthetic.reader.hath.network:6968/h/a/b/image.png")!, record: old, policy: policy)
        #expect(throws: AppError.accessDenied) {
            try BackgroundImageAdmission.validateResponse(syntheticOriginImage, record: old, policy: policy)
        }
    }
}
