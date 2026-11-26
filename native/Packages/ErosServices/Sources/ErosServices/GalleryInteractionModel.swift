import Foundation
import Observation
import ErosCore
import ErosNetworking

@MainActor @Observable public final class GalleryInteractionModel {
    public private(set) var snapshot: GalleryInteractionSnapshot?
    public private(set) var record: GalleryInteractionRecord?
    public private(set) var readback: GalleryDetail?
    public private(set) var metadataSaveFailed=false
    public private(set) var busy=false
    public private(set) var loaded=false
    public private(set) var checked=false
    public private(set) var message=""
    private let request: GalleryRequest
    private let service: GalleryInteractionService
    private let sessions: any SessionProvider
    private var work: Task<GalleryInteractionResult,any Error>?
    private var readWork:Task<GalleryInteractionReadback,any Error>?
    public init(request: GalleryRequest,service: GalleryInteractionService,sessions: any SessionProvider,snapshot: GalleryInteractionSnapshot?) {
        self.request=request;self.service=service;self.sessions=sessions;self.snapshot=snapshot
    }
    public var websiteURL:URL? { (try? EndpointBuilder().detail(request))?.url }
    public var unresolved:Bool { record?.state == .unknown || record?.state == .submitting }
    public var canSubmit:Bool { loaded && !busy && !unresolved }
    private func current() async -> Bool { (try? await sessions.current().scope)==request.scope }
    private func accept(_ record: GalleryInteractionRecord?) {
        self.record=record
        switch record?.state {
        case .submitting,.unknown: message="结果待确认。请先刷新或在网站核对，避免重复操作。"
        case .confirmed: message=record?.confirmedByUser == true ? "已由你确认操作结果。" : "网站已确认，数据已读回。"
        case .rejected: message="网站拒绝操作或当前权限不可用。"
        case .draft: message="操作未提交或已确认未成功。"
        case nil: message=""
        }
    }
    public func load() async {
        do { let value=try await service.store.load(request:request);try Task.checkCancellation();guard await current() else { return };accept(value);loaded=true }
        catch { message="操作记录读取失败，请检查会话或本机存储。" }
    }
    private func apply(_ value: GalleryInteractionReadback) { snapshot=value.snapshot;metadataSaveFailed=value.metadataSaveFailed;readback=value.detail }
    public func perform(_ action: GalleryInteractionAction) async {
        guard canSubmit else { return };busy=true;checked=false;defer { busy=false;work=nil }
        let task=Task { try await service.perform(action,request:request) };work=task
        do {
            let result=try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard await current() else { return };accept(result.record);if let value=result.readback { apply(value) }
        } catch {
            guard await current() else { return };message="操作未开始，请检查上次结果。"
            if let value=try? await service.store.load(request:request) { accept(value) }
        }
    }
    public func refresh() async {
        guard !busy else { return };busy=true;checked=false;defer { busy=false;readWork=nil }
        let expected=record?.id
        let task=Task { try await service.read(request:request) };readWork=task
        do {
            let value=try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard await current(),!Task.isCancelled else { return }
            let stored=try await service.store.load(request:request);guard await current() else { return }
            apply(value);accept(stored);checked=stored?.id==expected && stored?.state == .unknown
        } catch { if await current() { message="刷新失败，请检查网络后重试。" } }
    }
    public func resolve(success: Bool) async {
        guard checked,!busy,record?.state == .unknown,let id=record?.id else { return }
        do { let value=try await service.store.resolve(id:id,success:success,request:request);guard await current() else { return };accept(value);checked=false }
        catch { checked=false;message="记录已变化，请重新刷新核对。" }
    }
    public func cancel() { work?.cancel();readWork?.cancel() }
}
