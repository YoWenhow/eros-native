import Foundation
import ErosCore

public struct NetworkPolicy: Sendable {
    public let allowOriginalImageRequests: Bool
    public let allowArchiveWrite: Bool
    public let allowMyTagsWrite: Bool
    public let allowGalleryInteractions: Bool
    public let allowGalleryAPI: Bool
    public let allowGalleryTitleReads: Bool
    public let allowForumProfileRead: Bool
    public let allowForumAvatarRead: Bool
    public let allowImageQuotaReset: Bool
    public let allowMPVAPI: Bool
    public let parsing: ParsingPolicy
    public let mediaHosts: Set<String>
    public let allowHathThumbnailSprites: Bool
    public let allowHathReaderImages: Bool
    public init(parsing: ParsingPolicy = ParsingPolicy(), mediaHosts: Set<String> = [], allowHathThumbnailSprites: Bool = false, allowHathReaderImages: Bool = false, allowMPVAPI: Bool = false, allowGalleryAPI: Bool = false, allowGalleryInteractions: Bool = false, allowMyTagsWrite: Bool = false, allowOriginalImageRequests: Bool = false, allowArchiveWrite: Bool = false, allowGalleryTitleReads: Bool = false, allowForumProfileRead: Bool = false, allowForumAvatarRead: Bool = false, allowImageQuotaReset: Bool = false) {
        self.allowOriginalImageRequests = allowOriginalImageRequests
        self.allowArchiveWrite = allowArchiveWrite
        self.allowMyTagsWrite=allowMyTagsWrite
        self.allowGalleryInteractions=allowGalleryInteractions
        self.allowGalleryAPI = allowGalleryAPI
        self.allowGalleryTitleReads = allowGalleryTitleReads
        self.allowForumProfileRead = allowForumProfileRead
        self.allowForumAvatarRead = allowForumAvatarRead
        self.allowImageQuotaReset = allowImageQuotaReset
        self.allowMPVAPI = allowMPVAPI
        self.parsing = parsing; self.mediaHosts = Set(mediaHosts.map { $0.lowercased() })
        self.allowHathThumbnailSprites = allowHathThumbnailSprites
        self.allowHathReaderImages = allowHathReaderImages
    }
    public func isGalleryAPIEndpoint(_ url: URL, scope: SessionScope) -> Bool {
        (allowGalleryAPI || allowGalleryInteractions || allowMyTagsWrite) && url.scheme=="https" && url.user==nil && url.password==nil && url.port==nil && url.query==nil && url.fragment==nil && url.path=="/api.php" && url.host==(scope.storage.site == .eh ? "api.e-hentai.org" : "s.exhentai.org")
    }
    func isGalleryTitleEndpoint(_ url: URL, scope: SessionScope) -> Bool {
        allowGalleryTitleReads && url == GalleryTitleAPI.endpoint(for: scope, parsing: parsing)
    }
    public func isMPVEndpoint(_ url: URL, scope: SessionScope) -> Bool {
        allowMPVAPI && url.scheme == "https" && url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil && url.path == "/api.php" && url.host == (scope.storage.site == .eh ? "api.e-hentai.org" : "s.exhentai.org")
    }
    private func isForumProfile(_ url: URL) -> Bool {
        guard allowForumProfileRead, url.host == parsing.forumHost, url.path == "/index.php",
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              query.count == 1, query[0].name == "showuser",
              let value = query[0].value, let member = UInt64(value), member > 0 else { return false }
        return String(member) == value
    }

    public func validate(_ url: URL, scope: SessionScope, allowMedia: Bool = false) throws {
        if OriginalImageEndpoint.matchesPath(url), !allowOriginalImageRequests { throw AppError.accessDenied }
        let readerPeer = allowMedia && allowHathReaderImages && HathReaderURL.allows(url)
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 || readerPeer, url.fragment == nil,
              url.path.rangeOfCharacter(from: .controlCharacters) == nil,
              let host = url.host?.lowercased(), host == parsing.host(for: scope.storage.site) ||
                isMPVEndpoint(url, scope: scope) || isGalleryAPIEndpoint(url, scope: scope) || isGalleryTitleEndpoint(url, scope: scope) || isForumProfile(url) ||
                (allowMedia && (mediaHosts.contains(host) || isHathThumbnailSprite(url) || readerPeer ||
                    (allowForumAvatarRead && ProfileRecord.validAvatarURL(url)))) else { throw AppError.accessDenied }
    }
    private func isHathThumbnailSprite(_ url: URL) -> Bool {
        guard allowHathThumbnailSprites, let host = url.host?.lowercased(), url.query == nil,
              host.range(of: #"^[a-z0-9]{10}\.hath\.network$"#, options: .regularExpression) != nil else { return false }
        return url.path.range(of: #"^/c2/[A-Za-z0-9_-]{1,128}/[0-9]+-[0-9]+\.webp$"#, options: .regularExpression) != nil
    }
    /// Cross-host image redirects may reach only explicit media endpoints, never
    /// an account/page host merely because it is the current site.
    public func allowsMediaRedirect(to url: URL, scope: SessionScope) -> Bool {
        guard (try? validate(url, scope: scope, allowMedia: true)) != nil else { return false }
        return mediaHosts.contains(url.host?.lowercased() ?? "") || isHathThumbnailSprite(url)
            || (allowHathReaderImages && HathReaderURL.allows(url))
    }
    public func isLogin(_ url: URL) -> Bool {
        if url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
           [parsing.host(for: .eh), parsing.host(for: .ex)].contains(url.host?.lowercased() ?? ""), url.path == "/bounce_login.php" { return true }
        return url.scheme == "https" && url.host?.lowercased() == parsing.forumHost && url.user == nil && url.password == nil && (url.port == nil || url.port == 443) &&
        URLComponents(url: url,resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name.lowercased() == "act" && $0.value?.lowercased() == "login" } == true
    }
    public func validate(_ request: HTTPRequest) throws {
        let media = request.headers.first { $0.key.lowercased() == "accept" }?.value.hasPrefix("image/") == true
        try validate(request.url,scope: request.scope,allowMedia: media)
        if (isForumProfile(request.url) || ProfileRecord.validAvatarURL(request.url)), request.method != .get {
            throw AppError.accessDenied
        }
        for (key,value) in request.headers {
            // Credentials require the T18 domain/path-aware provider, not arbitrary per-call headers.
            guard !["cookie","authorization","proxy-authorization","host","connection","content-length"].contains(key.lowercased()),
                  !key.contains("\r"), !key.contains("\n"), !value.contains("\r"), !value.contains("\n") else { throw AppError.accessDenied }
        }
        guard request.method != .get || request.body == nil else { throw AppError.invalidInput }
        if request.method == .post, request.url.path == AccountOverviewEndpoint.quota.path {
            guard allowImageQuotaReset, request.scope.storage.site == .eh, request.url == AccountOverviewEndpoint.quota,
                  request.body == AccountOverviewEndpoint.resetBody,
                  request.headers.first(where: { $0.key.lowercased() == "content-type" })?.value == "application/x-www-form-urlencoded"
            else { throw AppError.accessDenied }
        }
        if request.method == .post, request.url.path == AccountOverviewEndpoint.gp.path { throw AppError.accessDenied }
        if request.url.path=="/archiver.php", request.method == .post {
            guard allowArchiveWrite,let body=request.body,body.count<=512,
                  request.headers.first(where:{$0.key.lowercased()=="content-type"})?.value=="application/x-www-form-urlencoded",
                  let encoded=String(data:body,encoding:.utf8) else { throw AppError.accessDenied }
            let query=URLComponents(url:request.url,resolvingAgainstBaseURL:false)?.queryItems ?? []
            guard query.count==2,query.filter({$0.name=="gid"}).count==1,query.filter({$0.name=="token"}).count==1,
                  let gidText=query.first(where:{$0.name=="gid"})?.value,let gid=Int64(gidText),gid>0,String(gid)==gidText,
                  let token=query.first(where:{$0.name=="token"})?.value,!token.isEmpty,token.utf8.count<=128 else {throw AppError.accessDenied}
            let fields=encoded.split(separator:"&",omittingEmptySubsequences:false).compactMap { item -> URLQueryItem? in
                let pair=item.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false)
                guard pair.count==2,let name=String(pair[0]).replacingOccurrences(of:"+",with:" ").removingPercentEncoding,
                      let value=String(pair[1]).replacingOccurrences(of:"+",with:" ").removingPercentEncoding else { return nil }
                return URLQueryItem(name:name,value:value)
            }
            guard fields.count==2,fields.filter({$0.name=="dltype"}).count==1,fields.filter({$0.name=="dlcheck"}).count==1 else { throw AppError.accessDenied }
            let type=fields.first(where:{$0.name=="dltype"})?.value,check=fields.first(where:{$0.name=="dlcheck"})?.value
            guard (type=="org" && check=="Download Original Archive") ||
                  (type=="res" && check=="Download Resample Archive") else { throw AppError.accessDenied }
        }
        if request.url.path=="/mytags",request.method == .post {
            guard allowMyTagsWrite,let body=request.body,body.count<=65536,
                  request.headers.first(where:{$0.key.lowercased()=="content-type"})?.value=="application/x-www-form-urlencoded" else { throw AppError.accessDenied }
            guard let encoded=String(data:body,encoding:.utf8) else {throw AppError.invalidInput}
            let fields=try encoded.split(separator:"&",omittingEmptySubsequences:false).map { item -> URLQueryItem in
                let pair=item.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false)
                guard pair.count==2,let name=String(pair[0]).replacingOccurrences(of:"+",with:" ").removingPercentEncoding,
                      let value=String(pair[1]).replacingOccurrences(of:"+",with:" ").removingPercentEncoding,
                      !name.isEmpty,!name.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else {throw AppError.invalidInput}
                return URLQueryItem(name:name,value:value)
            }
            guard fields.count<=100,fields.filter({$0.name=="usertag_action"}).count==1,fields.filter({$0.name=="usertag_target"}).count==1,
                  fields.first(where:{$0.name=="usertag_target"})?.value=="0",!fields.contains(where:{$0.name.hasPrefix("tagset_")}) else { throw AppError.accessDenied }
            let query=URLComponents(url:request.url,resolvingAgainstBaseURL:false)?.queryItems ?? []
            guard query.count<=1,query.allSatisfy({$0.name=="tagset" && (try? MyTagsIdentity.validate($0.value ?? "",allowZero:true)) != nil}) else { throw AppError.accessDenied }
            let action=fields.first(where:{$0.name=="usertag_action"})?.value
            let targets=fields.filter{$0.name=="modify_usertags[]"}
            guard (action=="add" && targets.isEmpty) || (action=="mass" && targets.count==1 && (try? MyTagsIdentity.validate(targets[0].value ?? "")) != nil) else { throw AppError.accessDenied }
        }

        if request.url.path == "/api.php",
           request.url.host == GalleryTitleAPI.endpoint(for: request.scope, parsing: parsing).host,
           allowGalleryTitleReads || GalleryTitleAPI.usesTitleMethod(request) {
            guard isGalleryTitleEndpoint(request.url, scope: request.scope) else { throw AppError.accessDenied }
            try GalleryTitleAPI.validate(request)
            return
        }
        if isGalleryAPIEndpoint(request.url,scope:request.scope) && !isMPVEndpoint(request.url,scope:request.scope) {
            guard request.method == .post, let body=request.body,body.count<=65536,
                  let object=try? JSONSerialization.jsonObject(with:body) as? [String:Any],let method=object["method"] as? String else { throw AppError.accessDenied }
            let base:Set<String>=["method","apiuid","apikey","gid","token"]
            switch method {
            case "setusertag" where allowMyTagsWrite:
                struct Value:Decodable { let tagid:Int64;let tagwatch:Int;let taghide:Int;let tagcolor:String;let tagweight:String }
                guard Set(object.keys)==Set(["method","apiuid","apikey","tagid","tagwatch","taghide","tagcolor","tagweight"]),let value=try? JSONDecoder().decode(Value.self,from:body),value.tagid>0,
                      [0,1].contains(value.tagwatch),[0,1].contains(value.taghide),let weight=Int(value.tagweight),String(weight)==value.tagweight,
                      let props=try? MyTagsProperties(watched:value.tagwatch==1,hidden:value.taghide==1,color:value.tagcolor,weight:weight),props.color==value.tagcolor else { throw AppError.accessDenied }
            case "votecomment" where allowGalleryAPI: guard Set(object.keys)==base.union(["comment_id","comment_vote"]) else { throw AppError.accessDenied }
            case "rategallery" where allowGalleryInteractions:
                struct Value:Decodable { let rating:Int }
                guard Set(object.keys)==base.union(["rating"]),let value=try? JSONDecoder().decode(Value.self,from:body),(1...10).contains(value.rating) else { throw AppError.accessDenied }
            case "taggallery" where allowGalleryInteractions:
                struct Value:Decodable { let tags:String;let vote:Int }
                guard Set(object.keys)==base.union(["tags","vote"]),let value=try? JSONDecoder().decode(Value.self,from:body),let colon=value.tags.firstIndex(of:":"),
                      let tag=try? TagMutation(namespace:String(value.tags[..<colon]),original:String(value.tags[value.tags.index(after:colon)...]),direction:value.vote),tag.canonical==value.tags else { throw AppError.accessDenied }
            default: throw AppError.accessDenied
            }
        }
    }
}

public enum ResponseKind: Sendable { case html, json, image, mpvJSON, galleryTitlesJSON, galleryMutationJSON, galleryInteractionJSON, myTagsMutationJSON }
public struct ResponseClassifier: Sendable {
    public let policy: NetworkPolicy
    public init(policy: NetworkPolicy = NetworkPolicy()) { self.policy = policy }
    public static func header(_ name: String, in response: HTTPResponse) -> String? { response.headers.first { $0.key.lowercased() == name.lowercased() }?.value }
    public static func retryAfter(_ raw: String?, now: Date) -> TimeInterval? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Double(text), n.isFinite { return n }
        let formatter = DateFormatter();formatter.locale = Locale(identifier: "en_US_POSIX");formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'";formatter.isLenient = false
        guard let date = formatter.date(from: text) else { return nil }
        return max(0,date.timeIntervalSince(now))
    }
    public func validate(_ response: HTTPResponse, request: HTTPRequest, kind: ResponseKind, now: Date) throws {
        try Task.checkCancellation()
        guard response.scope == request.scope, response.requestID == request.id else { throw AppError.staleSession }
        if policy.isLogin(response.finalURL) { throw AppError.authenticationRequired }
        try policy.validate(response.finalURL,scope: request.scope,allowMedia: kind == .image)
        if (300...399).contains(response.status), let location = Self.header("location",in: response),
           let target = URL(string: location,relativeTo: response.finalURL)?.absoluteURL, policy.isLogin(target) { throw AppError.authenticationRequired }
        switch response.status {
        case 200: break
        case 401: throw AppError.authenticationRequired
        case 403: throw kind == .image ? AppError.imageExpired : AppError.accessDenied
        case 404 where kind == .image: throw AppError.imageExpired
        case 410 where kind == .image: throw AppError.imageExpired
        case 429: throw AppError.rateLimited(retryAfter: Self.retryAfter(Self.header("retry-after",in: response),now: now))
        case 509: throw AppError.quotaExceeded
        default: throw AppError.httpStatus(response.status)
        }
        let mime = Self.header("content-type",in: response)?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .html:
            guard mime == "text/html" || mime == "application/xhtml+xml" else { throw AppError.unsupportedContent }
            guard let text = String(data: response.body,encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.parseMismatch }
            if !text.contains("<"), text.lowercased().contains("banned") { throw AppError.accessDenied }
        case .myTagsMutationJSON:
            guard policy.allowMyTagsWrite,policy.isGalleryAPIEndpoint(request.url,scope:request.scope),response.finalURL==request.url,
                  request.method == .post,response.body.count<=1024*1024,mime=="application/json" || mime=="text/html",
                  let body=request.body,let sent=try? JSONSerialization.jsonObject(with:body) as? [String:Any],sent["method"] as? String=="setusertag",
                  (try? JSONSerialization.jsonObject(with:response.body)) is [String:Any] else { throw AppError.unsupportedContent }
            try policy.validate(request)
        case .galleryInteractionJSON:
            guard policy.allowGalleryInteractions,policy.isGalleryAPIEndpoint(request.url,scope:request.scope),response.finalURL==request.url,
                  request.method == .post,response.body.count<=1024*1024,mime=="application/json" || mime=="text/html",
                  let body=request.body,let sent=try? JSONSerialization.jsonObject(with:body) as? [String:Any],
                  ["rategallery","taggallery"].contains(sent["method"] as? String ?? ""),
                  (try? JSONSerialization.jsonObject(with:response.body)) is [String:Any] else { throw AppError.unsupportedContent }
            try policy.validate(request)
        case .galleryTitlesJSON:
            guard policy.isGalleryTitleEndpoint(request.url, scope: request.scope), response.finalURL == request.url,
                  response.body.count <= 2 * 1024 * 1024, mime == "application/json" || mime == "text/html" else {
                throw AppError.unsupportedContent
            }
            try policy.validate(request)
        case .galleryMutationJSON:
            guard policy.isGalleryAPIEndpoint(request.url,scope:request.scope), response.finalURL==request.url,
                  request.method == .post, response.body.count<=1024*1024,
                  mime=="application/json" || mime=="text/html",
                  let body=request.body, let sent=try? JSONSerialization.jsonObject(with:body) as? [String:Any],
                  sent["method"] as? String == "votecomment",
                  (try? JSONSerialization.jsonObject(with:response.body)) is [String:Any] else { throw AppError.unsupportedContent }
        case .mpvJSON:
            guard policy.isMPVEndpoint(request.url, scope: request.scope), response.finalURL == request.url,
                  request.method == .post, response.body.count <= 1024 * 1024,
                  mime == "application/json" || mime == "text/html" else { throw AppError.unsupportedContent }
            guard (try? JSONSerialization.jsonObject(with: response.body)) is [String: Any] else { throw AppError.parseMismatch }
        case .json:
            guard mime == "application/json" else { throw AppError.unsupportedContent }
            do { _ = try JSONSerialization.jsonObject(with: response.body) } catch { throw AppError.parseMismatch }
        case .image:
            try ImageResolutionPolicy.validateImageResponse(response,scope: request.scope)
        }
    }
}

public struct RetryPolicy: Sendable {
    public init() {}
    public func delay(request: HTTPRequest, error: AppError, retries: Int, serverDelay: TimeInterval? = nil) -> TimeInterval? {
        guard request.method == .get, retries < 2 else { return nil }
        let names = Set(URLComponents(url: request.url,resolvingAgainstBaseURL: false)?.queryItems?.map { $0.name.lowercased() } ?? [])
        guard names.isDisjoint(with: ["inline_set","act","action","profile_action"]) else { return nil }
        let retryable: Bool
        switch error {
        case .transport(let code): retryable = [-1001,-1005,-1004].contains(code)
        case .httpStatus(let code): retryable = [502,503,504].contains(code)
        case .rateLimited: retryable = true
        default: retryable = false
        }
        guard retryable else { return nil }
        let delay: TimeInterval
        if case .rateLimited(let after) = error { delay = max(pow(2,Double(retries)),after ?? 0) }
        else { delay = max(pow(2,Double(retries)),serverDelay ?? 0) }
        // Never shorten a long server delay: return control to UI instead of retrying early.
        return delay.isFinite && delay <= 60 ? delay : nil
    }
}

public struct SystemNetworkClock: Clock {
    public init() {}
    public func now() async -> Date { Date() }
    public func sleep(seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

public struct HTTPClient: Sendable {
    public let transport: any HTTPTransport
    public let clock: any Clock
    public let classifier: ResponseClassifier
    public init(transport: any HTTPTransport, clock: any Clock = SystemNetworkClock(), policy: NetworkPolicy = NetworkPolicy()) {
        self.transport = transport;self.clock = clock;classifier = ResponseClassifier(policy: policy)
    }
    public func send(_ request: HTTPRequest, expecting kind: ResponseKind, retryTransportFailures: Bool = true, retryRateLimits: Bool = true) async throws -> HTTPResponse {
        try classifier.policy.validate(request)
        var retries = 0
        while true {
            try Task.checkCancellation()
            var serverDelay: TimeInterval?
            do {
                let response = try await transport.send(request: request)
                let now = await clock.now()
                serverDelay = ResponseClassifier.retryAfter(ResponseClassifier.header("retry-after",in: response),now: now)
                try classifier.validate(response,request: request,kind: kind,now: now)
                return response
            } catch let error as AppError {
                if case .transport = error, !retryTransportFailures { throw error }
                if case .rateLimited = error, !retryRateLimits { throw error }
                guard let delay = RetryPolicy().delay(request: request,error: error,retries: retries,serverDelay: serverDelay) else { throw error }
                retries += 1;try await clock.sleep(seconds: delay)
            }
        }
    }
}
