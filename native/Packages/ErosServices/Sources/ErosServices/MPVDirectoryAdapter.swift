import Foundation
import ErosCore

/// Reader-owned memory context. No networking, persistence, implicit fallback or key refresh.
/// F06b must invalidate it on every session/mode change and guard live requests separately.
public actor MPVDirectoryAdapter {
    private let parser: MPVDirectoryParser
    private var context: RequestContext?
    private var directory: MPVDirectory?
    public init(parser: MPVDirectoryParser = MPVDirectoryParser()) { self.parser = parser }
    public func begin(scope: SessionScope) -> RequestContext {
        directory = nil
        let ticket = RequestContext(scope: scope, queryID: UUID()); context = ticket
        return ticket
    }
    public func accept(_ response: HTTPResponse, reference: GalleryReference, ticket: RequestContext, expectedCount: Int) throws {
        try Task.checkCancellation()
        guard context == ticket else { throw AppError.invalidInput }
        directory = nil
        directory = try parser.parse(response, reference: reference, context: ticket, expectedCount: expectedCount)
    }
    public func page(at index: PageIndex, ticket: RequestContext) throws -> MPVPageLocator {
        try Task.checkCancellation()
        guard context == ticket, let directory else { throw AppError.invalidInput }
        return try directory.page(at: index, scope: ticket.scope)
    }
    public func capability() -> MPVCapability { directory?.capability ?? .unknown }
    public func invalidate() { context = nil; directory = nil }
}
