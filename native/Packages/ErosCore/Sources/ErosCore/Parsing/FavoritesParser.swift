import Foundation
import SwiftSoup

public struct FavoritePopup: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let groups: [FavoriteGroup]
    public let selectedGroup: String?
    public let note: String
    public let actionURL: URL
    public let fields: [String: String]
    public var isFavorite: Bool { selectedGroup != nil }
    public var description: String { "<favorite-form redacted>" }
    public var debugDescription: String { description }
}
public protocol RemoteFavoritesRepository: FavoritesRepository {
    func popup(request: GalleryRequest) async throws -> FavoritePopup
}
public enum FavoriteWriteFailure: Error, Sendable { case pending, unconfirmed }

public struct FavoritesParser: Sendable {
    public let policy: ParsingPolicy
    public init(policy: ParsingPolicy = ParsingPolicy()) { self.policy = policy }
    public func groups(_ response: HTTPResponse, context: RequestContext) throws -> [FavoriteGroup] {
        try HTMLParsing.mapped {
            let doc = try HTMLParsing.document(response, context: context, policy: policy)
            return try groups(in: doc, response: response, context: context)
        }
    }

    private func groups(in doc: Document, response: HTTPResponse, context: RequestContext) throws -> [FavoriteGroup] {
        guard response.finalURL.path == "/favorites.php" else { throw AppError.parseMismatch }
        let rows = try doc.select("body > div.ido > div.nosel > div.fp").array().filter { $0.children().array().count >= 3 }
        guard rows.count == 10 else { throw AppError.parseMismatch }
        var ids: Set<String> = []
        return try rows.map { row in
            let children = row.children().array()
            guard children.count >= 3,
                  let raw = try HTMLParsing.capture(row.attr("onclick"), #"^document\.location='([^']+)'\s*;?$"#) else { throw AppError.parseMismatch }
            let url = try policy.siteURL(raw, base: response.finalURL, site: context.scope.storage.site)
            let categories = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "favcat" } ?? []
            guard url.path == "/favorites.php", categories.count == 1,
                  let id = categories[0].value, let number = Int(id), (0...9).contains(number), String(number) == id,
                  ids.insert(id).inserted, let title = try HTMLParsing.text(children[2]),
                  let count = try HTMLParsing.count(HTMLParsing.text(children[0])) else { throw AppError.parseMismatch }
            return FavoriteGroup(id: id, title: title, count: count)
        }
    }

    public func list(_ response: HTTPResponse, request: FavoritesListRequest) throws -> PagedResult<GallerySummary> {
        try HTMLParsing.mapped {
            let doc = try HTMLParsing.document(response, context: request.context, policy: policy)
            let groups = try groups(in: doc, response: response, context: request.context)
            let selected = request.groupID.flatMap { id in groups.first { $0.id == id } }
            let total = selected?.count?.value ?? groups.reduce(0) { $0 + ($1.count?.value ?? 0) }
            let noTitleMatches = try request.titleQuery != nil &&
                doc.select("body > div.ido > p, body > div.ido > div > p").array().contains {
                    try HTMLParsing.text($0) == "No hits found"
                }
            if total == 0 || noTitleMatches {
                guard try doc.select(".itg .glink, .itg .gl1t").isEmpty() else { throw AppError.parseMismatch }
                let navigation = try HTMLParsing.pagination(doc, response: response, context: request.context, policy: policy)
                guard navigation.next == nil && navigation.previous == nil else { throw AppError.parseMismatch }
                return try PagedResult(items: [], context: request.context)
            }
            return try GalleryListParser(policy: policy).parse(response, context: request.context, sharedFavoriteLinks: true)
        }
    }
    public func popup(_ response: HTTPResponse, request: GalleryRequest) throws -> FavoritePopup {
        try HTMLParsing.mapped {
            let context = RequestContext(scope: request.scope, queryID: UUID())
            let doc = try HTMLParsing.document(response, context: context, policy: policy)
            try validatePopupURL(response.finalURL, request: request)
            let forms = try doc.select("form#galpop").array()
            guard forms.count == 1, try forms[0].attr("method").lowercased() == "post" else { throw AppError.parseMismatch }
            let form = forms[0], action = try form.attr("action")
            let target = action.isEmpty ? response.finalURL : try policy.siteURL(action, base: response.finalURL, site: request.scope.storage.site)
            try validatePopupURL(target, request: request)
            var groups: [FavoriteGroup] = [], selected: String?, canRemove = false
            var seen: Set<String> = []
            for radio in try form.select("input[type=radio][name=favcat]").array() {
                let id = try radio.attr("value")
                guard seen.insert(id).inserted, !radio.hasAttr("disabled") else { throw AppError.parseMismatch }
                if id == "favdel" { canRemove = true }
                else {
                    guard let n = Int(id), (0...9).contains(n), String(n) == id,
                          let row = radio.parent()?.parent(), row.children().array().count >= 3,
                          let title = try HTMLParsing.text(row.children().array()[2]) else { throw AppError.parseMismatch }
                    groups.append(FavoriteGroup(id: id, title: title))
                }
                if radio.hasAttr("checked") { guard selected == nil else { throw AppError.parseMismatch }; selected = id }
            }
            guard groups.count == 10, let selected, selected != "favdel" else { throw AppError.parseMismatch }
            var fields: [String: String] = [:]
            for input in try form.select("input[type=hidden], input[type=submit][name]").array() {
                let name = try input.attr("name"), value = try input.attr("value")
                guard !name.isEmpty, name.count <= 128, value.utf8.count <= 8192,
                      fields[name] == nil, !["favcat", "favnote"].contains(name) else { throw AppError.parseMismatch }
                fields[name] = value
            }
            let notes = try form.select("textarea[name=favnote]").array()
            guard fields["update"] != nil, fields["apply"] != nil, fields.count <= 32, notes.count == 1 else { throw AppError.parseMismatch }
            return FavoritePopup(groups: groups, selectedGroup: canRemove ? selected : nil,
                note: try notes[0].text(trimAndNormaliseWhitespace: false), actionURL: target, fields: fields)
        }
    }
    private func validatePopupURL(_ url: URL, request: GalleryRequest) throws {
        _ = try policy.siteURL(url.absoluteString, base: url, site: request.scope.storage.site)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard url.path == "/gallerypopups.php", url.fragment == nil, query.count == 3,
              query.filter({ $0.name == "gid" }).map(\.value) == [String(request.reference.key.galleryID.value)],
              query.filter({ $0.name == "t" }).map(\.value) == [request.reference.token.value],
              query.filter({ $0.name == "act" }).map(\.value) == ["addfav"] else { throw AppError.parseMismatch }
    }
}
