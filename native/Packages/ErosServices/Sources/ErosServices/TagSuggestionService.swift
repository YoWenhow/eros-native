import Foundation
import ErosCore
import ErosNetworking

public struct TagSuggestionService:Sendable {
    let client:HTTPClient
    let sessions:any SessionProvider
    public init(client:HTTPClient,sessions:any SessionProvider) { self.client=client;self.sessions=sessions }
    public func suggestions(text:String,scope:SessionScope) async throws -> [TagTranslationKey] {
        guard try await sessions.current().scope == scope else { throw AppError.staleSession }
        let request=try EndpointBuilder(policy:client.classifier.policy).tagSuggestions(text:text,scope:scope)
        let response=try await client.send(request,expecting:.json,retryTransportFailures:false,retryRateLimits:false)
        try Task.checkCancellation()
        guard try await sessions.current().scope == scope else { throw AppError.staleSession }
        return try Self.parse(response.body)
    }
    public static func parse(_ data:Data) throws -> [TagTranslationKey] {
        guard data.count<=1_048_576,let root=try JSONSerialization.jsonObject(with:data) as? [String:Any],let tags=root["tags"] as? [String:Any],tags.count<=500 else { throw AppError.parseMismatch }
        var result=[TagTranslationKey]()
        for id in tags.keys.sorted() {
            guard let row=tags[id] as? [String:Any],let ns=row["ns"] as? String,let name=row["tn"] as? String,let key=try? TagTranslationKey(namespace:ns,original:name) else { throw AppError.parseMismatch }
            if SearchAssistance.formula(key) != nil && !result.contains(key) { result.append(key) }
        }
        return Array(result.prefix(50))
    }
}
