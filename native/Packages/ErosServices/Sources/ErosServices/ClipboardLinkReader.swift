import Foundation
import ErosCore

public struct ClipboardLinkSnapshot:Sendable {
    public let text:String?
    public let changed:Bool
    public init(text:String?,changed:Bool=false) {self.text=text;self.changed=changed}
}
@MainActor public protocol ClipboardLinkProvider {
    func snapshot() async -> ClipboardLinkSnapshot
}
@MainActor public struct ClipboardLinkReader {
    public init() {}
    public func read(provider:any ClipboardLinkProvider) async throws -> [GalleryLinkCandidate] {
        let snapshot=await provider.snapshot()
        try Task.checkCancellation()
        guard !snapshot.changed else{throw ClipboardLinkError.changed}
        guard let text=snapshot.text else{throw ClipboardLinkError.unavailable}
        return try ClipboardLinkCandidates.parse(text)
    }
}
