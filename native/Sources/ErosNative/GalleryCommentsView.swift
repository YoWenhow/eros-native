import SwiftUI
import ErosCore
import ErosServices

struct GalleryCommentsView: View {
    let services: AppContainer
    let reference: GalleryReference
    let scope: SessionScope
    let readOnly:Bool
    @State var page: CommentPage?
    init(services: AppContainer, reference: GalleryReference, scope: SessionScope, page: CommentPage?, readOnly:Bool = false) {
        self.readOnly=readOnly
        self.services = services; self.reference = reference; self.scope = scope
        _page = State(initialValue: page)
    }
    @Environment(\.openGalleryLink) private var openGalleryLink
    @State private var mutations: CommentMutationModel?
    @State private var showComposer = false
    @State private var work: Task<Void, Never>?
    @State private var retry = 0
    @State private var loading = false
    @State private var failure: String?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if loading {
                    ProgressView().accessibilityLabel("正在加载评论")
                        .frame(maxWidth: .infinity)
                }
                if let failure { Text(failure).foregroundStyle(.red) }
                if let mutations, !mutations.message.isEmpty { Text(mutations.message).font(.footnote).foregroundStyle(.secondary) }
                if let page = mutations?.page ?? page {
                    if page.hasOwnCommentWithoutVoting {
                        Text("本画廊已有你的评论，网站不再允许赞或踩。").font(.footnote).foregroundStyle(.secondary)
                    }
                    if page.items.isEmpty { Text("暂无评论").frame(maxWidth: .infinity) }
                    ForEach(page.items) { comment in
                        CommentRow(comment:comment,receipt:mutations?.votes[comment.id],busy:loading || mutations == nil || mutations?.busy == true || mutations?.unresolved == true,readOnly:readOnly) { direction in
                            Task { await mutations?.vote(id:comment.id,direction:direction) }
                        } reply: {
                            Task { if await mutations?.prepareReply(commentID:comment.id) == true { showComposer=true } }
                        }.environment(\.openURL,OpenURLAction {url in
                            switch CommentLinkPolicy.action(url) {
                            case .gallery:openGalleryLink(url);return .handled
                            case .browser(let safe):return .systemAction(safe)
                            case .inert:return .discarded
                            }
                        })
                    }
                    if !page.items.isEmpty {
                        Text("显示网站本次返回的评论").font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                } else if !loading && failure == nil {
                    Text("暂时无法识别评论结构，请刷新重试。").frame(maxWidth: .infinity)
                }
            }.padding().background(NativeMainScrollAnchor())
        }.background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("评论").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !readOnly { Button { showComposer=true } label: { Label(mutations?.unresolved == true ? "核对操作" : "写评论",systemImage:mutations?.unresolved == true ? "exclamationmark.bubble" : "square.and.pencil") }.disabled(loading || mutations == nil || mutations?.busy == true) }
            Button { retry += 1 } label: { Label("刷新",systemImage:"arrow.clockwise") }.disabled(loading || mutations?.busy == true)
        }
        .sheet(isPresented:$showComposer) { if let mutations { CommentComposerSheet(model:mutations) } }
        .task {
            if readOnly { if page == nil {await refresh()};return }
            if page == nil {await refresh()}
            guard !Task.isCancelled,mutations == nil, let request=try? GalleryRequest(reference:reference,scope:scope) else { return }
            let value=CommentMutationModel(request:request,service:services.commentMutations,store:services.commentDrafts,sessions:services.sessions,page:page)
            await value.load();guard !Task.isCancelled else { return };mutations=value
        }
        .task(id: retry) { if retry > 0 { await refresh() } }
        .refreshable { await refresh() }
        .onDisappear { work?.cancel(); work = nil; mutations?.cancelWaiting() }
        .nativeTabPage()
    }
    private func refresh() async {
        guard !loading, mutations?.busy != true else { return }
        loading = true
        let task = Task { await load() }; work = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    private func load() async {
        defer { loading = false; work = nil }
        do {
            guard try await services.sessions.current().scope == scope else { throw AppError.staleSession }
            let detail = try await services.galleries.detail(request: GalleryRequest(reference:reference,scope:scope))
            try Task.checkCancellation()
            guard try await services.sessions.current().scope == scope else { throw AppError.staleSession }
            guard let comments = detail.comments else { throw AppError.parseMismatch }
            page = comments; mutations?.acceptPage(comments); failure = nil
        } catch is CancellationError {} catch {
            guard !Task.isCancelled else { return }
            switch error as? AppError {
            case .authenticationRequired,.accessDenied,.staleSession:
                page = nil; failure = "会话已变化或没有读取权限，请在「设置 → 当前账号」检查。"
            case .parseMismatch: failure = "暂时无法识别评论结构，请稍后重试。"
            default: failure = "评论加载失败，请检查网络后重试。"
            }
        }
    }
}
private struct CommentRow: View {
    let comment: GalleryComment
    let receipt: CommentVoteReceipt?
    let busy: Bool
    let readOnly:Bool
    let vote: (CommentVoteDirection) -> Void
    let reply: () -> Void
    @State private var expanded = false
    @Environment(\.openURL) private var openURL
    private var segments:[CommentBodySegment] {CommentBodyPresentation.segments(for:comment)}
    private var links:[URL] {var seen=Set<URL>();return segments.compactMap(\.target).filter{seen.insert($0).inserted}}
    private var attributed:AttributedString {
        var result=AttributedString()
        for segment in segments {
            var value=AttributedString(segment.text)
            if let target=segment.target {value.link=target}
            result.append(value)
        }
        return result
    }
    private func timestamp(_ time: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"; return formatter.string(from:time)
    }
    var body: some View {
        VStack(alignment: .leading,spacing: 8) {
            HStack {
                if comment.id == "0" { Text("上传者评论").font(.subheadline) }
                else if let author = comment.author { Text(author).font(.subheadline) }
                Spacer()
                if let score = receipt?.score ?? comment.score { Text("得分 \(score)").font(.caption).foregroundStyle(.secondary) }
            }
            if let time = comment.postedAt { Text(timestamp(time)).font(.caption).foregroundStyle(.secondary) }
            // Construct runs explicitly; user Markdown/HTML never becomes executable content.
            Text(attributed).font(.body).lineLimit(expanded ? nil : 8).textSelection(.enabled)
            if !links.isEmpty {
                Menu {
                    ForEach(links, id: \.self) { url in
                        Button(url.absoluteString, systemImage: "link") { openURL(url) }
                    }
                } label:{Label("链接地址",systemImage:"link").font(.caption)}
                .accessibilityHint("查看实际网址，选择后打开")
            }
            if !readOnly && (comment.canVoteUp == true || comment.canVoteDown == true || comment.replyPrefix != nil) {
                HStack(spacing:20) {
                    if comment.replyPrefix != nil { Button(action:reply) { Label("回复",systemImage:"arrowshape.turn.up.left") }.font(.caption) }
                    if comment.canVoteUp == true { Button { vote(.up) } label: { Image(systemName:(receipt?.vote ?? comment.myVote ?? 0) > 0 ? "hand.thumbsup.fill" : "hand.thumbsup") }.accessibilityLabel("赞") }
                    if comment.canVoteDown == true { Button { vote(.down) } label: { Image(systemName:(receipt?.vote ?? comment.myVote ?? 0) < 0 ? "hand.thumbsdown.fill" : "hand.thumbsdown") }.accessibilityLabel("踩") }
                }.buttonStyle(.plain).foregroundStyle(.tint).disabled(busy)
            }
            // Character counts cannot predict wrapping at accessibility text sizes.
            // Keep an explicit full-text route for every nonempty comment.
            if !comment.body.isEmpty {
                Button(expanded ? "收起" : "展开全文") { expanded.toggle() }.font(.caption)
            }
        }.frame(maxWidth:.infinity,alignment:.leading).padding()
            .background(.background,in:RoundedRectangle(cornerRadius:16))
    }
}
