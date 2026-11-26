import Foundation
import ErosCore

/// The site's read-only gdata request, scoped to the originating site.
public enum GalleryTitleAPI {
    public static let batchSize = 25

    static func endpoint(for scope: SessionScope, parsing: ParsingPolicy) -> URL {
        let host = scope.storage.site == .eh ? "api.e-hentai.org" : parsing.host(for: .ex)
        return URL(string: "https://" + host + "/api.php")!
    }

    private struct Payload: Codable {
        let method: String
        let gidlist: [GalleryIdentifier]

        struct GalleryIdentifier: Codable {
            let id: Int64
            let token: String

            init(_ reference: GalleryReference) {
                id = reference.key.galleryID.value
                token = reference.token.value
            }

            init(from decoder: any Decoder) throws {
                var tuple = try decoder.unkeyedContainer()
                id = try tuple.decode(Int64.self)
                token = try tuple.decode(String.self)
                guard tuple.isAtEnd else { throw AppError.invalidInput }
            }

            func encode(to encoder: any Encoder) throws {
                var tuple = encoder.unkeyedContainer()
                try tuple.encode(id)
                try tuple.encode(token)
            }
        }
    }

    static func usesTitleMethod(_ request: HTTPRequest) -> Bool {
        guard let body = request.body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return object["method"] as? String == "gdata"
    }

    static func validate(_ request: HTTPRequest) throws {
        guard request.method == .post, let body = request.body, body.count <= 4096,
              request.headers.first(where: { $0.key.lowercased() == "content-type" })?.value == "application/json",
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              Set(object.keys) == ["method", "gidlist"],
              let payload = try? JSONDecoder().decode(Payload.self, from: body),
              payload.method == "gdata", (1...batchSize).contains(payload.gidlist.count),
              payload.gidlist.allSatisfy({ entry in
                  entry.id > 0 && entry.token.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil
              }) else { throw AppError.accessDenied }
    }

    public static func load(_ references: [GalleryReference], scope: SessionScope,
                            client: HTTPClient) async throws -> [GalleryReference: GallerySourceTitles] {
        let policy = client.classifier.policy
        guard policy.allowGalleryTitleReads else { throw AppError.accessDenied }
        for reference in references { try reference.validate(scope: scope) }
        let payload = Payload(method: "gdata", gidlist: references.map(Payload.GalleryIdentifier.init))
        let request = HTTPRequest(id: UUID(), scope: scope, url: endpoint(for: scope, parsing: policy.parsing),
            method: .post, headers: ["Accept": "application/json", "Content-Type": "application/json"],
            body: try JSONEncoder().encode(payload))
        let reply = try await client.send(request, expecting: .galleryTitlesJSON)
        return try GalleryTitleMetadataParser.parse(reply.body, requested: references)
    }
}
