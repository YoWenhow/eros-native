import Foundation
import ErosCore

public struct EndpointBuilder: Sendable {
    public let policy: NetworkPolicy
    public init(policy: NetworkPolicy = NetworkPolicy()) { self.policy = policy }
    private func make(path: String, scope: SessionScope, query: [URLQueryItem] = [], method: HTTPMethod = .get, body: Data? = nil, json: Bool = false) throws -> HTTPRequest {
        var parts = URLComponents();parts.scheme = "https";parts.host = policy.parsing.host(for: scope.storage.site);parts.path = path
        parts.queryItems = query.isEmpty ? nil : query
        // '+' is literal search syntax, not a form-encoded space.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+",with: "%2B")
        guard let url = parts.url else { throw AppError.invalidInput }
        let request = HTTPRequest(id: UUID(),scope: scope,url: url,method: method,
            headers: json ? ["Accept":"application/json","Content-Type":"application/json"] : ["Accept":"text/html,application/xhtml+xml","Accept-Language":"zh-CN,zh;q=0.9,en;q=0.8"],body: body)
        try policy.validate(request);return request
    }
    private func component(_ value: String) throws -> String {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw AppError.invalidInput };return value
    }
    public func list(_ request: GalleryListRequest) throws -> HTTPRequest {
        if let cursor = request.cursor {
            var url = try policy.parsing.navigationURL(cursor: cursor,context: request.context)
            if case .toplist = request.query.source {} else {
                var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                // Site cursors use form encoding: "+" separates terms, and "%2B" is a literal plus.
                let query = (parts.percentEncodedQueryItems ?? []).filter { $0.name.removingPercentEncoding != "inline_set" }
                parts.percentEncodedQueryItems = query + [URLQueryItem(name: "inline_set", value: "dm_l")]
                guard let compact = parts.url else { throw AppError.invalidInput }; url = compact
            }
            let result = HTTPRequest(id: UUID(),scope: request.context.scope,url: url,method: .get,headers: ["Accept":"text/html"])
            try policy.validate(result);return result
        }
        var path = "/", query: [URLQueryItem] = [URLQueryItem(name: "inline_set", value: "dm_l")]
        switch request.query.source {
        case .browse: break
        case .watched: path = "/watched"
        case .popular: return try make(path: "/popular",scope: request.context.scope, query: query)
        case .toplist(let period):
            guard request.context.scope.storage.site == .eh else { throw AppError.scopeMismatch }
            guard ["11","12","13","15"].contains(period) else { throw AppError.invalidInput }
            return try make(path: "/toplist.php",scope: request.context.scope,query: [URLQueryItem(name: "tl",value: period)])
        }
        if !request.query.terms.isEmpty { query.append(URLQueryItem(name: "f_search",value: request.query.terms)) }
        let categories = ["Misc":1,"Doujinshi":2,"Manga":4,"Artist CG":8,"Game CG":16,"Image Set":32,"Cosplay":64,"Asian Porn":128,"Non-H":256,"Western":512]
        var mask = 0
        for category in request.query.excludedCategories { guard let bit = categories[category] else { throw AppError.invalidInput };mask |= bit }
        if mask != 0 { query.append(URLQueryItem(name: "f_cats",value: String(mask))) }
        if let filters = request.query.filters {
            var advanced: [URLQueryItem] = []
            func flag(_ enabled: Bool,_ name: String) { if enabled { advanced.append(URLQueryItem(name: name,value: "on")) } }
            flag(filters.requireTorrent,"f_sto");flag(filters.includeExpunged,"f_sh")
            flag(filters.disableLanguageFilter,"f_sfl");flag(filters.disableUploaderFilter,"f_sfu");flag(filters.disableTagFilter,"f_sft")
            if let rating = filters.minimumRating {
                guard (2...5).contains(rating.value) else { throw AppError.invalidInput }
                flag(true,"f_sr");advanced.append(URLQueryItem(name: "f_srdd",value: String(rating.value)))
            }
            if filters.minimumPageCount != nil || filters.maximumPageCount != nil {
                flag(true,"f_sp")
                if let n = filters.minimumPageCount { advanced.append(URLQueryItem(name: "f_spf",value: String(n.value))) }
                if let n = filters.maximumPageCount { advanced.append(URLQueryItem(name: "f_spt",value: String(n.value))) }
            }
            if !advanced.isEmpty { query.append(URLQueryItem(name: "advsearch",value: "1"));query += advanced }
        }
        return try make(path: path,scope: request.context.scope,query: query)
    }
    public func detail(_ request: GalleryRequest, thumbnailPage: Int? = nil) throws -> HTTPRequest {
        if let thumbnailPage, thumbnailPage < 0 { throw AppError.invalidInput }
        return try make(path: "/g/\(request.reference.key.galleryID.value)/\(component(request.reference.token.value))/",scope: request.scope,
                        query: thumbnailPage.map { [URLQueryItem(name: "p",value: String($0))] } ?? [])
    }
    public func imagePage(_ page: ReaderPage, scope: SessionScope, sourceID: SensitiveText? = nil) throws -> HTTPRequest {
        try page.reference.validate(scope: scope)
        try policy.validate(page.pageURL,scope: scope)
        var parts = URLComponents(url: page.pageURL,resolvingAgainstBaseURL: false)!
        let path = page.pageURL.path.split(separator: "/")
        guard path.count == 3, path[0] == "s", path[2] == "\(page.reference.key.galleryID.value)-\(page.index.displayNumber)" else { throw AppError.invalidInput }
        _ = try component(String(path[1]))
        var query = parts.queryItems?.filter { $0.name != "nl" } ?? []
        if let sourceID { query.append(URLQueryItem(name: "nl",value: sourceID.value)) }
        parts.queryItems = query.isEmpty ? nil : query
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+",with: "%2B")
        guard let url = parts.url else { throw AppError.invalidInput }
        return HTTPRequest(id: UUID(),scope: scope,url: url,method: .get,headers: ["Accept":"text/html"])
    }
    public func showPage(_ page: ReaderPage, scope: SessionScope, showKey: SensitiveText) throws -> HTTPRequest {
        let html = try imagePage(page,scope: scope)
        let key = String(html.url.path.split(separator: "/")[1])
        let body = try JSONSerialization.data(withJSONObject: ["method":"showpage","gid":page.reference.key.galleryID.value,"page":page.index.displayNumber,"imgkey":key,"showkey":showKey.value])
        return try make(path: "/api.php",scope: scope,method: .post,body: body,json: true)
    }
    public func media(url: URL, scope: SessionScope) throws -> HTTPRequest {
        try policy.validate(url,scope: scope,allowMedia: true)
        return HTTPRequest(id: UUID(),scope: scope,url: url,method: .get,headers: ["Accept":"image/jpeg,image/png,image/gif,image/webp,image/avif"])
    }
    public func tagSuggestions(text:String,scope:SessionScope) throws -> HTTPRequest {
        guard !text.isEmpty,text.count<=256 else { throw AppError.invalidInput }
        let body=try JSONSerialization.data(withJSONObject:["method":"tagsuggest","text":text])
        return try make(path:"/api.php",scope:scope,method:.post,body:body,json:true)
    }
    public func favorites(_ request: FavoritesListRequest) throws -> HTTPRequest {
        var query = [URLQueryItem(name: "inline_set", value: "dm_l")]
        if let group = request.groupID, group != "a" {
            guard let number = Int(group), (0...9).contains(number) else { throw AppError.invalidInput }
            query.append(URLQueryItem(name: "favcat", value: String(number)))
        }
        if let title = request.titleQuery {
            // Keep the user's fragment inside the website's title qualifier.
            let words = title.split { $0.isWhitespace || $0 == "\"" }
            let phrase = String(words.joined(separator: " ").prefix(192))
            guard !phrase.isEmpty else { throw AppError.invalidInput }
            query.append(URLQueryItem(name: "f_search", value: "title:\"\(phrase)\""))
        }
        let initial = try make(path: "/favorites.php", scope: request.context.scope, query: query)
        guard let cursor = request.cursor else { return initial }

        let cursorURL = try policy.parsing.navigationURL(cursor: cursor, context: request.context)
        guard cursorURL.path == "/favorites.php",
              let cursorParts = URLComponents(url: cursorURL, resolvingAgainstBaseURL: false),
              var parts = URLComponents(url: initial.url, resolvingAgainstBaseURL: false) else { throw AppError.invalidInput }
        let managed: Set = ["inline_set", "favcat", "f_search", "sn", "st", "sf"]
        let pagination = (cursorParts.percentEncodedQueryItems ?? []).filter {
            !managed.contains($0.name.removingPercentEncoding ?? $0.name)
        }
        parts.percentEncodedQueryItems = pagination + (parts.percentEncodedQueryItems ?? [])
        guard let url = parts.url else { throw AppError.invalidInput }
        let next = HTTPRequest(id: initial.id, scope: initial.scope, url: url, method: .get, headers: initial.headers)
        try policy.validate(next)
        return next
    }
    public func favoritePopup(_ request: GalleryRequest) throws -> HTTPRequest {
        try request.reference.validate(scope: request.scope)
        return try make(path: "/gallerypopups.php", scope: request.scope, query: [
            URLQueryItem(name: "gid", value: String(request.reference.key.galleryID.value)),
            URLQueryItem(name: "t", value: component(request.reference.token.value)),
            URLQueryItem(name: "act", value: "addfav")])
    }
    public func favoriteMutation(_ mutation: FavoriteMutation, form: FavoritePopup) throws -> HTTPRequest {
        let original = try favoritePopup(GalleryRequest(reference: mutation.reference, scope: mutation.scope))
        guard form.actionURL == original.url else { throw AppError.scopeMismatch }
        var fields = form.fields
        switch mutation.action {
        case .add(let id, let note):
            guard form.groups.contains(where: { $0.id == id }) else { throw AppError.invalidInput }
            fields["favcat"] = id; fields["favnote"] = note ?? form.note
        case .remove:
            guard form.isFavorite else { throw AppError.invalidInput }
            fields["favcat"] = "favdel"; fields["favnote"] = form.note
        }
        guard (fields["favnote"]?.utf8.count ?? 0) <= 8192 else { throw AppError.invalidInput }
        var parts = URLComponents()
        parts.queryItems = fields.keys.sorted().map { URLQueryItem(name: $0, value: fields[$0]) }
        guard let encoded = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") else { throw AppError.invalidInput }
        let request = HTTPRequest(id: UUID(), scope: mutation.scope, url: form.actionURL, method: .post,
            headers: ["Accept":"text/html", "Content-Type":"application/x-www-form-urlencoded"], body: Data(encoded.utf8))
        try policy.validate(request); return request
    }
    public func commentPost(_ mutation: CommentMutation, form: CommentPostForm) throws -> HTTPRequest {
        let expected = try detail(mutation.request)
        guard case .post = mutation.action, form.action == expected.url else { throw AppError.accessDenied }
        if let maximum=form.maximumLength { guard mutation.text.count<=maximum else { throw AppError.invalidInput } }
        var fields=form.fields.mapValues(\.value); fields["commenttext_new"]=mutation.text
        var components=URLComponents();components.queryItems=fields.keys.sorted().map { URLQueryItem(name:$0,value:fields[$0]) }
        guard let body=components.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B") else { throw AppError.invalidInput }
        let request=HTTPRequest(id:UUID(),scope:mutation.request.scope,url:form.action,method:.post,
            headers:["Accept":"text/html","Content-Type":"application/x-www-form-urlencoded"],body:Data(body.utf8))
        try policy.validate(request);return request
    }
    public func commentVote(_ mutation: CommentMutation, api: CommentAPI) throws -> HTTPRequest {
        guard case .vote(let id,let direction)=mutation.action, api.scope==mutation.request.scope,
              policy.isGalleryAPIEndpoint(api.endpoint,scope:api.scope), let comment=Int64(id),comment>0 else { throw AppError.accessDenied }
        let body=try JSONSerialization.data(withJSONObject:["method":"votecomment","apiuid":api.userID,"apikey":api.key.value,
            "gid":mutation.request.reference.key.galleryID.value,"token":mutation.request.reference.token.value,
            "comment_id":comment,"comment_vote":direction.rawValue])
        let request=HTTPRequest(id:UUID(),scope:api.scope,url:api.endpoint,method:.post,
            headers:["Accept":"application/json","Content-Type":"application/json"],body:body)
        try policy.validate(request);return request
    }

    public func galleryInteraction(_ action: GalleryInteractionAction,request: GalleryRequest,api: CommentAPI) throws -> HTTPRequest {
        try action.validate();try request.reference.validate(scope:request.scope)
        guard policy.allowGalleryInteractions,api.scope==request.scope,policy.isGalleryAPIEndpoint(api.endpoint,scope:api.scope) else { throw AppError.accessDenied }
        var fields:[String:Any]=["apiuid":api.userID,"apikey":api.key.value,"gid":request.reference.key.galleryID.value,"token":request.reference.token.value]
        switch action {
        case .rating(let value): fields["method"]="rategallery";fields["rating"]=value.steps
        case .tag(let value): fields["method"]="taggallery";fields["tags"]=value.canonical;fields["vote"]=value.direction
        }
        let result=HTTPRequest(id:UUID(),scope:api.scope,url:api.endpoint,method:.post,headers:["Accept":"application/json","Content-Type":"application/json"],body:try JSONSerialization.data(withJSONObject:fields))
        try policy.validate(result);return result
    }

    public func myTags(scope: SessionScope,setID: String?=nil) throws -> HTTPRequest {
        if let setID { try MyTagsIdentity.validate(setID,allowZero:true) }
        // Website change_tagset navigates to the base view for set 1.
        let query=setID.flatMap { $0=="1" ? nil : URLQueryItem(name:"tagset",value:$0) }
        return try make(path:"/mytags",scope:scope,query:query.map{[$0]} ?? [])
    }

    public func myTagsUpdate(_ action:MyTagsMutation,scope:SessionScope,api:CommentAPI) throws -> HTTPRequest {
        try action.validate();guard policy.allowMyTagsWrite,case .update(let base,let props)=action,api.scope==scope,policy.isGalleryAPIEndpoint(api.endpoint,scope:scope),let tagID=Int64(base.tagID) else { throw AppError.accessDenied }
        let fields:[String:Any]=["method":"setusertag","apiuid":api.userID,"apikey":api.key.value,"tagid":tagID,"tagwatch":props.watched ? 1 : 0,"taghide":props.hidden ? 1 : 0,"tagcolor":props.color,"tagweight":String(props.weight)]
        let request=HTTPRequest(id:UUID(),scope:scope,url:api.endpoint,method:.post,headers:["Accept":"application/json","Content-Type":"application/json"],body:try JSONSerialization.data(withJSONObject:fields));try policy.validate(request);return request
    }
    public func myTagsForm(_ action:MyTagsMutation,scope:SessionScope,form:MyTagsWriteForm) throws -> HTTPRequest {
        try action.validate();guard policy.allowMyTagsWrite,form.action==(try myTags(scope:scope,setID:action.setID)).url else { throw AppError.accessDenied }
        var values=form.hidden
        for name in ["tagname_new","tagcolor_new","tagweight_new","tagwatch_new","taghide_new","usertag_target"] { guard values[name]==nil else { throw AppError.parseMismatch } }
        values["usertag_target"]="0";values["tagname_new"]="";values["tagcolor_new"]="";values["tagweight_new"]="10"
        switch action {
        case .add(_,_,_,let props):
            guard form.canAdd else { throw AppError.accessDenied }
            values["usertag_action"]="add";values["tagname_new"]=action.canonical;values["tagcolor_new"]=props.color;values["tagweight_new"]=String(props.weight)
            if props.watched { values["tagwatch_new"]="on" };if props.hidden { values["taghide_new"]="on" }
        case .remove(let base): guard form.removableIDs.contains(base.tagID) else { throw AppError.accessDenied };values["usertag_action"]="mass";values["modify_usertags[]"]=base.tagID
        case .update: throw AppError.invalidInput
        }
        var parts=URLComponents();parts.queryItems=values.keys.sorted().map{URLQueryItem(name:$0,value:values[$0]!)}
        guard let encoded=parts.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B") else { throw AppError.invalidInput }
        let request=HTTPRequest(id:UUID(),scope:scope,url:form.action,method:.post,headers:["Accept":"text/html","Content-Type":"application/x-www-form-urlencoded"],body:Data(encoded.utf8));try policy.validate(request);return request
    }

}
