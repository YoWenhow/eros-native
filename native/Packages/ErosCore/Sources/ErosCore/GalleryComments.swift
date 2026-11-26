import Foundation
import SwiftSoup

public struct GalleryComment: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let author: String?
    public let body: String
    public let bodySegments:[CommentBodySegment]?
    public let postedAt: Date?
    public let score: Int?
    public let canVoteUp: Bool?
    public let canVoteDown: Bool?
    public let myVote: Int?
    public let canEdit: Bool?
    /// A reply is a new comment with a visible mention, not a separate wire API.
    public var replyPrefix: String? {
        guard let author=author?.trimmingCharacters(in:.whitespacesAndNewlines),!author.isEmpty,
              author.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              let number=Int64(id),number>=0,String(number)==id else { return nil }
        return "@"+author+" #"+id+"#\n"
    }
}
public struct CommentCursor: Codable, Equatable, Sendable {
    public let context: RequestContext
    public let url: URL
}
public struct CommentPage: Codable, Equatable, Sendable {
    public let items: [GalleryComment]
    public let next: CommentCursor?
    public var hasOwnCommentWithoutVoting: Bool {
        items.contains { $0.id != "0" && $0.canEdit == true } &&
        !items.contains { $0.canVoteUp == true || $0.canVoteDown == true }
    }
}
public struct GalleryCommentsParser: Sendable {
    public init() {}
    public func parse(html: String,baseURL:URL? = nil) throws -> CommentPage {
        let doc = try SwiftSoup.parse(html)
        guard let container = try doc.select("#cdiv").first() else { throw AppError.parseMismatch }
        let rows = try container.select("div.c1").array()
        guard rows.count <= 1000 else { throw AppError.unsupportedContent }
        var items: [GalleryComment] = []; var ids = Set<String>()
        for row in rows {
            try Task.checkCancellation()
            guard let content = try row.select(".c6").first() else { throw AppError.parseMismatch }
            let rawID = try content.attr("id")
            guard rawID.hasPrefix("comment_"), let id = Int64(rawID.dropFirst(8)), id >= 0,
                  ids.insert(String(id)).inserted else { throw AppError.parseMismatch }
            // One bounded DOM walk creates both the copyable body and attributed runs.
            enum Work {case node(Node,URL?,Bool);case text(String,URL?,Bool)}
            var pending:[Work]=[.node(content,nil,true)]
            var rawBody="";var segments:[CommentBodySegment]=[];var degraded=false;var links=0;var visited=0
            func append(_ value:String,_ target:URL?,_ detect:Bool) {
                rawBody+=value
                guard !degraded else{return}
                let runs:[CommentBodySegment]
                if let target {runs=[.link(label:value,target:target,origin:.anchor)]}
                else {runs=detect ? BareWebLinks.segments(value) : [.text(value)]}
                for run in runs where !run.text.isEmpty {
                    if run.target != nil && segments.last?.target != run.target {links+=1}
                    segments.append(run)
                    if links>CommentBodyPresentation.maximumLinks || segments.count>CommentBodyPresentation.maximumSegments {
                        degraded=true;segments=[];return
                    }
                }
            }
            while let next=pending.popLast() {
                visited+=1;if visited%64==0 {try Task.checkCancellation()}
                switch next {
                case .text(let value,let target,let detect):append(value,target,detect)
                case .node(let node,let target,let detect):
                    if let text=node as? TextNode {append(text.getWholeText(),target,detect);continue}
                    let tag=(node as? Element)?.tagName()
                    if let tag,["script","style","iframe","object","embed","img","svg","form","input","button"].contains(tag) {continue}
                    if tag=="br" {append("\n",target,false);continue}
                    let block=tag.map{["p","div","li","blockquote"].contains($0)} ?? false
                    if block {append("\n",target,false);pending.append(.text("\n",target,false))}
                    var childTarget=target;var childDetect=detect
                    if tag=="a",let anchor=node as? Element {
                        childTarget=CommentLinkPolicy.webURL(try anchor.attr("href"),relativeTo:baseURL);childDetect=false
                    }
                    for child in node.getChildNodes().reversed() {pending.append(.node(child,childTarget,childDetect))}
                }
            }
            let body=rawBody.trimmingCharacters(in:.whitespacesAndNewlines)
            guard body.utf8.count<=100_000 else{throw AppError.unsupportedContent}
            if degraded {segments=[.text(body)]}
            else {
                func trim(_ run:CommentBodySegment,leading:Bool) -> CommentBodySegment {
                    let chars=run.text.unicodeScalars
                    let value=leading ? String(String.UnicodeScalarView(chars.drop(while:{CharacterSet.whitespacesAndNewlines.contains($0)}))) :
                        String(String.UnicodeScalarView(chars.reversed().drop(while:{CharacterSet.whitespacesAndNewlines.contains($0)}).reversed()))
                    if let target=run.target{return .link(label:value,target:target,origin:run.origin)};return .text(value)
                }
                while let first=segments.first {
                    segments[0]=trim(first,leading:true)
                    if segments[0].text.isEmpty {segments.removeFirst()} else {break}
                }
                while let last=segments.last {
                    segments[segments.count-1]=trim(last,leading:false)
                    if segments.last?.text.isEmpty==true {segments.removeLast()} else {break}
                }
                // Coalesce adjacent attributes using a single append buffer, bounded by raw run count.
                var merged:[CommentBodySegment]=[];var buffer="";var target:URL?;var origin:CommentLinkOrigin?
                func flush() {
                    guard !buffer.isEmpty else{return}
                    if let target {merged.append(.link(label:buffer,target:target,origin:origin))} else {merged.append(.text(buffer))}
                    buffer=""
                }
                for run in segments {
                    if run.target != target || run.origin != origin {flush();target=run.target;origin=run.origin}
                    buffer.append(run.text)
                }
                flush();segments=merged
                if segments.map(\.text).joined() != body {segments=[.text(body)]}
            }
            let authorText = try row.select(".c3 a").first()?.text()
            let author = authorText?.isEmpty == false ? authorText : nil
            let scoreText = try row.select(".c5 span").first()?.text()
            let score = scoreText.flatMap(Int.init)
            var date: Date?
            let metadata = try row.select(".c3").text()
            let pattern = #"\d{1,2} [A-Za-z]+ \d{4}, \d{2}:\d{2}"#
            if let range = metadata.range(of: pattern, options: .regularExpression) {
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "d MMMM yyyy, HH:mm"
                formatter.isLenient = false; date = formatter.date(from: String(metadata[range]))
            }
            let up = try row.select(".c4 a[id=comment_vote_up_\(id)]").first()
            let down = try row.select(".c4 a[id=comment_vote_down_\(id)]").first()
            func allows(_ element: Element?, _ function: String) throws -> Bool {
                guard id > 0, let element else { return false }
                guard !element.parents().array().contains(where:{ ((try? $0.attr("class")) ?? "").split(separator:" ").contains("c6") }) else { return false }
                return try element.attr("onclick").range(of:"^\\s*" + function + "\\(\\s*" + String(id) + "\\s*\\)",options:.regularExpression) != nil
            }
            let canUp = try allows(up,"vote_comment_up"), canDown = try allows(down,"vote_comment_down")
            let upStyle = try up?.attr("style").lowercased() ?? "", downStyle = try down?.attr("style").lowercased() ?? ""
            let myVote: Int? = upStyle.contains("blue") ? 1 : downStyle.contains("blue") ? -1 : (canUp && canDown && upStyle.isEmpty && downStyle.isEmpty ? 0 : nil)
            let canEdit = try row.select(".c4 a[onclick]").array().contains { try allows($0,"edit_comment") }
            items.append(GalleryComment(id: String(id), author: author, body: body, bodySegments:segments, postedAt: date, score: score, canVoteUp: canUp, canVoteDown: canDown, myVote: myVote, canEdit: canEdit))
        }
        if rows.isEmpty {
            let text = try container.text().lowercased()
            guard text.contains("no comments") else { throw AppError.parseMismatch }
        }
        // No independent cursor protocol is evidenced. Do not invent pagination
        // or describe this detail-response subset as the complete comment history.
        return CommentPage(items: items, next: nil)
    }
}
