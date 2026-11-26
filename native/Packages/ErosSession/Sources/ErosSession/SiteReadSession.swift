import Foundation
import ErosCore
import ErosNetworking

/// A navigation-local, read-only credential lease. It never changes or persists the active site.
/// Every boundary is still authorized by the exact live owner/scope and credential identity.
struct ReadCredentialIdentity:Equatable,Sendable {
    let key:String
    let value:String
    let secure:Bool
    let httpOnly:Bool
    let hostOnly:Bool
}
public actor SiteReadSession: SessionProvider, RequestCredentials {
    private let parent: SessionManager
    private let origin: SessionScope
    private let identity: [ReadCredentialIdentity]
    private let state: SessionState
    private var cookies: [SessionCookie]
    private var revoked = false
    init(parent: SessionManager, origin: SessionScope, identity: [ReadCredentialIdentity], state: SessionState, cookies: [SessionCookie]) {
        self.parent=parent; self.origin=origin; self.identity=identity; self.state=state; self.cookies=cookies
    }
    public func current() async throws -> SessionState {
        guard !revoked else { throw AppError.staleSession }
        try await parent.checkReadAuthorization(origin:origin, identity:identity)
        try Task.checkCancellation()
        guard !revoked else { throw AppError.staleSession }
        if cookies.contains(where: { ["ipb_member_id","ipb_pass_hash","igneous"].contains($0.name) && ($0.expires.map{$0<=Date()} ?? false) }) {
            revoked=true; throw AppError.authenticationRequired
        }
        return state
    }
    private func check(_ scope: SessionScope) async throws {
        guard try await current().scope == scope else { throw AppError.staleSession }
    }
    public func register(id:UUID,scope:SessionScope,cancel:@escaping @Sendable () -> Void) async throws {
        try await check(scope)
        // The live manager cancels this request on logout/site/profile generation change.
        try await parent.register(id:id,scope:origin,cancel:cancel)
        do { try await check(scope) } catch { await parent.unregister(id:id); cancel(); throw error }
    }
    public func unregister(id:UUID) async { await parent.unregister(id:id) }
    public func authorize(_ request:HTTPRequest) async throws {
        try await check(request.scope)
        guard request.method == .get,request.body == nil else{throw AppError.accessDenied}
        if request.url.host == (state.scope.storage.site == .eh ? "e-hentai.org" : "exhentai.org") {
            guard SiteReadTransport.allows(request.url) else{throw AppError.accessDenied}
        } else {
            let image=request.headers.first{$0.key.lowercased()=="accept"}?.value.hasPrefix("image/")==true
            guard image else{throw AppError.accessDenied}
            try NetworkPolicy(mediaHosts:["ehgt.org","s.exhentai.org"],allowHathThumbnailSprites:true,allowHathReaderImages:true)
                .validate(request.url,scope:request.scope,allowMedia:true)
        }
    }
    public func cookieHeader(url:URL,scope:SessionScope) async throws -> String? {
        try await check(scope)
        guard url.host == (scope.storage.site == .eh ? "e-hentai.org" : "exhentai.org") else { return nil }
        guard SiteReadTransport.allows(url) else { throw AppError.accessDenied }
        let matched=cookies.filter{$0.matches(url,now:Date())}.sorted{$0.path.count>$1.path.count}
        return matched.isEmpty ? nil : matched.map{$0.name+"="+$0.value}.joined(separator:"; ")
    }
    public func receive(headers:[String:String],url:URL,scope:SessionScope) async throws {
        try await check(scope)
        guard url.host == (scope.storage.site == .eh ? "e-hentai.org" : "exhentai.org") else { return }
        var next=cookies
        for c in try SessionCookie.parse(headers:headers,origin:url) {
            next.removeAll{$0.key==c.key}
            if c.expires.map({$0>Date()}) ?? true { next.append(c) }
        }
        guard Self.identity(next)==Self.identity(cookies) else {
            revoked=true; throw AppError.authenticationRequired
        }
        cookies=next
    }
    static func identity(_ cookies:[SessionCookie]) -> [ReadCredentialIdentity] {
        cookies.filter{["ipb_member_id","ipb_pass_hash","igneous"].contains($0.name)}
            .sorted{$0.key<$1.key}.map{ReadCredentialIdentity(key:$0.key,value:$0.value,secure:$0.secure,httpOnly:$0.httpOnly,hostOnly:$0.hostOnly)}
    }
}

/// Enforces GET-only browsing before any transport work. No action URL or API POST is reachable.
public struct SiteReadTransport: HTTPTransport {
    private let base:any HTTPTransport
    private let sessions:any SessionProvider
    public init(base:any HTTPTransport,sessions:any SessionProvider) { self.base=base; self.sessions=sessions }
    public static func allows(_ url:URL) -> Bool {
        guard url.scheme=="https",url.user==nil,url.password==nil,url.port==nil || url.port==443,
              url.fragment==nil,["e-hentai.org","exhentai.org"].contains(url.host?.lowercased() ?? "") else{return false}
        let page=url.path=="/" || url.path.range(of:#"^/g/[0-9]+/[a-fA-F0-9]{10}/?$|^/s/[a-fA-F0-9]{10}/[0-9]+-[0-9]+$"#,options:.regularExpression) != nil
        guard page else{return false}
        let allowed:Set<String>=["p","f_search","f_cats","f_sto","f_sh","f_sfl","f_sfu","f_sft","f_sr","f_srdd","f_sp","f_spf","f_spt","advsearch","next","prev","hc","nl"]
        return (URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems ?? []).allSatisfy {
            allowed.contains($0.name) || ($0.name=="inline_set" && $0.value=="dm_l")
        }
    }
    public func send(request:HTTPRequest) async throws -> HTTPResponse {
        guard request.method == .get,request.body==nil,Self.allows(request.url) else{throw AppError.accessDenied}
        guard try await sessions.current().scope == request.scope else{throw AppError.staleSession}
        let response=try await base.send(request:request)
        try Task.checkCancellation()
        guard try await sessions.current().scope == request.scope else{throw AppError.staleSession}
        guard Self.allows(response.finalURL) else{throw AppError.accessDenied}
        return response
    }
}
