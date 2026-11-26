import Foundation
import Observation
import ErosCore
import ErosNetworking

@MainActor @Observable public final class CommentMutationModel {
    public var text = ""
    public private(set) var draft: CommentDraft?
    public private(set) var busy = false
    public private(set) var refreshing = false
    public private(set) var checked = false
    public private(set) var page: CommentPage?
    public private(set) var votes: [String:CommentVoteReceipt] = [:]
    public private(set) var message = ""
    private let request: GalleryRequest
    private let service: CommentMutationService
    private let store: CommentDraftStore
    private let sessions: any SessionProvider
    private var cancellationRequested = false
    private var work: Task<CommentMutationResult, any Error>?
    private var readWork: Task<CommentPage, any Error>?
    private var saveWork: Task<Void,Never>?
    public init(request: GalleryRequest, service: CommentMutationService, store: CommentDraftStore, sessions: any SessionProvider, page: CommentPage?) {
        self.request=request;self.service=service;self.store=store;self.sessions=sessions;self.page=page
    }
    public var websiteURL: URL? {
        guard let url=(try? EndpointBuilder().detail(request))?.url else { return nil }
        var parts=URLComponents(url:url,resolvingAgainstBaseURL:false)
        if let action=draft?.action,case .vote(let id,_)=action { parts?.fragment="comment_"+id }
        return parts?.url
    }
    public var unresolved: Bool { draft?.state == .unknown || draft?.state == .submitting }
    public var canSend: Bool { draft != nil && !busy && !unresolved && !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && text.utf8.count<=65536 }
    private func current() async -> Bool { (try? await sessions.current().scope)==request.scope }
    private func apply(_ value: CommentDraft) {
        draft=value;text=value.body
        switch value.state {
        case .draft: message=value.reason == .cancelled ? "已结束等待，草稿保留。" : ""
        case .submitting,.unknown: message="结果待确认，请先刷新核对，避免重复提交。"
        case .confirmed: message=value.confirmedByUser ? "已由你确认操作结果。" : "操作已由网站确认。"
        case .rejected: message=value.reason == .unavailable ? "当前页面暂不支持此操作，草稿已保留。" : "操作被拒绝或权限不可用，草稿已保留。"
        }
    }
    public func load() async {
        do { let value=try await store.load(request:request);try Task.checkCancellation();guard await current() else { return };apply(value) }
        catch { message="草稿未能读取，请检查会话和本机存储。" }
    }
    public func scheduleSave() {
        guard draft != nil, !busy, !unresolved, text != draft?.body else { return }
        saveWork?.cancel()
        saveWork=Task { do { try await Task.sleep(for:.milliseconds(300)); _=await save() } catch {} }
    }
    public func save() async -> Bool {
        guard !busy,!unresolved else { return false }
        do {
            let value=try await store.save(text:text,request:request)
            guard await current() else { return false };draft=value;return true
        } catch { if !Task.isCancelled { message="草稿未能保存，请重试或复制正文留存。" };return false }
    }
    public func discard() async -> Bool { saveWork?.cancel();text="";return await save() }
    public func prepareReply(commentID: String) async -> Bool {
        guard draft != nil,!busy,!unresolved,
              let comment=page?.items.first(where:{$0.id==commentID}),let prefix=comment.replyPrefix else { return false }
        saveWork?.cancel();saveWork=nil;busy=true
        defer { busy=false }
        let proposed=text.hasPrefix(prefix) ? text : prefix+text
        guard proposed.utf8.count<=65536 else { message="草稿过长，请先缩短正文再回复。";return false }
        do {
            let saved=try await store.save(text:proposed,request:request)
            guard await current() else { return false }
            apply(saved);return true
        } catch { if await current() { message="回复草稿未能保存，请重试。" };return false }
    }
    public func post() async { await perform(.post) }
    public func vote(id: String, direction: CommentVoteDirection) async { await perform(.vote(id:id,direction:direction)) }
    private func perform(_ action: CommentAction) async {
        guard draft != nil,!busy,!unresolved else { return }
        saveWork?.cancel();saveWork=nil;cancellationRequested=false;busy=true;message="";checked=false
        defer { busy=false;work=nil }
        do {
            let snapshot=text
            let saved=try await store.save(text:snapshot,request:request)
            guard await current() else { return };draft=saved
            if cancellationRequested { message="已结束等待，草稿保留。";return }
            let mutation=try CommentMutation(request:request,action:action,text:snapshot)
            let task=Task { try await service.perform(mutation) };work=task
            let result=try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            // A cancelled wait still publishes its persisted unknown outcome, but
            // an old owner/session can never publish into a current page.
            guard await current() else { return }
            apply(result.draft)
            if let page=result.page { self.page=page }
            if result.draft.state == .confirmed, let receipt=result.vote { votes[receipt.id]=receipt }
        } catch {
            guard await current() else { return }
            message="操作未开始或正在处理中，请先检查草稿与上次结果。"
            if let value=try? await store.load(request:request) { apply(value) }
        }
    }
    public func acceptPage(_ page: CommentPage) { self.page=page;votes=[:] }
    public func refreshForConfirmation() async {
        guard !busy,!refreshing else { return };refreshing=true;defer { refreshing=false;readWork=nil }
        let expected=draft?.operationID
        let task=Task { try await service.read(request:request) };readWork=task
        do {
            let page=try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard await current(),!Task.isCancelled else { return }
            let value=try await store.load(request:request)
            guard await current() else { return }
            apply(value);acceptPage(page)
            guard value.operationID == expected else { checked=false;message="操作记录已变化，请重新刷新核对。";return }
            checked=true
        } catch { if await current() { message="刷新核对失败，请检查网络后重试。" } }
    }
    public func resolve(success: Bool) async -> Bool {
        guard checked,!busy,draft?.state == .unknown,let operationID=draft?.operationID else { return false }
        do { let value=try await store.resolve(request:request,operationID:operationID,success:success);guard await current() else { return false };apply(value);checked=false;return true }
        catch { checked=false;message="核对结果未能保存，请重新刷新。";return false }
    }
    public func cancelWaiting() { cancellationRequested=true;work?.cancel();readWork?.cancel();saveWork?.cancel() }
}
