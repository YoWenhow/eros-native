import Foundation
import Observation
import ErosCore
import ErosNetworking

@MainActor @Observable public final class MyTagsWriteModel {
    public private(set) var batch:MyTagsMutationBatch?
    public private(set) var snapshot:MyTagsSnapshot?
    public private(set) var cacheSaveFailed=false
    public private(set) var busy=false
    public private(set) var loaded=false
    public private(set) var stopRequested=false
    public private(set) var message=""
    public private(set) var checkedAttempt:UUID?
    public let scope:SessionScope
    private let service:MyTagsWriteService
    private let sessions:any SessionProvider
    private var work:Task<MyTagsWriteResult,any Error>?
    private var checkWork:Task<MyTagsReadResult,any Error>?
    private var checkedStep:UUID?
    private var checkedBatch:UUID?
    public init(service:MyTagsWriteService,sessions:any SessionProvider,scope:SessionScope) { self.service=service;self.sessions=sessions;self.scope=scope }
    public func validateScope() async -> Bool {
        guard await current() else {work?.cancel();checkWork?.cancel();batch=nil;snapshot=nil;loaded=false;checkedAttempt=nil;message="会话已变化，请重新打开。";return false};return true
    }
    public var canStage:Bool { loaded && !busy && batch?.unresolved != true && batch?.hasDrafts != true }
    private func current() async->Bool { (try? await sessions.current().scope)==scope }
    public func load() async {
        do { let value=try await service.store.load(scope:scope);guard await current(),!Task.isCancelled else{return};batch=value;loaded=true }
        catch { message="操作记录未能读取，请检查会话和本机存储。" }
    }
    public func submit(_ actions:[MyTagsMutation]) async {
        guard canStage else{return};busy=true;defer{busy=false}
        do { batch=try await service.store.stage(actions,scope:scope);guard await current() else{return};await execute() }
        catch { if await current(){message="草稿未能保存或仍有待处理操作，请先核对记录。"} }
    }
    public func runPending() async {
        guard loaded,!busy,batch?.unresolved != true,batch?.hasDrafts == true else{return};busy=true;defer{busy=false};await execute()
    }
    private func execute() async {
        stopRequested=false;checkedAttempt=nil;message=""
        while !stopRequested,let batch,let next=batch.steps.first(where:{$0.state == .draft}) {
            if let index=self.batch?.steps.firstIndex(where:{$0.id==next.id}) {self.batch?.steps[index].state = .submitting}
            let task=Task{try await service.perform(batchID:batch.id,stepID:next.id,scope:scope)};work=task
            do {
                let result=try await withTaskCancellationHandler { try await task.value } onCancel:{task.cancel()}
                guard await validateScope() else{return};self.batch=result.batch
                if let snapshot=result.snapshot {self.snapshot=snapshot};cacheSaveFailed=result.cacheSaveFailed
                guard let finished=result.batch.steps.first(where:{$0.id==next.id}),finished.state == .confirmed else { message="当前项未确认成功，后续未发送项已暂停。";break }
            } catch {
                guard await current() else{return};self.batch=try? await service.store.load(scope:scope);message="操作未开始或记录已变化，请重新读取。";break
            }
        }
        work=nil
        if stopRequested {message="已停止后续操作，未发送项仍保留。"}
    }
    public func stopAfterCurrent() { stopRequested=true;message="当前项会继续完成，后续项暂停。" }
    public func cancelWaiting() { stopRequested=true;work?.cancel();checkWork?.cancel() }
    public func checkUnknown() async {
        guard !busy else{return}
        do {let value=try await service.store.load(scope:scope);guard await validateScope(),!busy else{return};self.batch=value}
        catch {message="操作记录未能重新读取，请稍后重试。";return}
        guard let batch,let step=batch.steps.first(where:{$0.state == .unknown}),let attempt=step.attemptID else{message="当前没有可核对的未知项；若仍在处理中，请稍后重试。";return}
        busy=true;checkedAttempt=nil;defer{busy=false;checkWork=nil}
        let task=Task{try await service.read(scope:scope,setID:step.action.setID)};checkWork=task
        do {
            let result=try await withTaskCancellationHandler {try await task.value} onCancel:{task.cancel()}
            guard await current(),!Task.isCancelled else{return}
            let stored=try await service.store.load(scope:scope);guard await current() else{return}
            self.batch=stored;snapshot=result.snapshot;cacheSaveFailed=result.cacheSaveFailed
            guard stored?.id==batch.id,stored?.steps.contains(where:{$0.id==step.id && $0.attemptID==attempt && $0.state == .unknown})==true else {message="操作记录已变化，请重新核对。";return}
            checkedBatch=batch.id;checkedStep=step.id;checkedAttempt=attempt;message="请核对当前网站数据，再明确选择结果。"
        } catch { if await current(){message="核对读取失败，请恢复网络后重试。"} }
    }
    public func resolve(success:Bool) async {
        guard !busy,let id=checkedBatch,let step=checkedStep,let attempt=checkedAttempt else{return}
        do {let value=try await service.resolve(batchID:id,stepID:step,attemptID:attempt,success:success,scope:scope);guard await current() else{return};batch=value;checkedAttempt=nil;message=success ? "已由你确认成功。" : "已保留草稿，再次提交前仍会检查冲突。"}
        catch {checkedAttempt=nil;message="记录已变化，请重新刷新核对。"}
    }
    public func discardUnsent() async {
        guard !busy else{return};do {let value=try await service.store.discardUnsent(scope:scope);guard await current() else{return};batch=value} catch {message="未发送项未能更新，请重试。"}
    }
    public func rebase(_ stepID:UUID) async {
        guard !busy,let batch else{return}
        do {let value=try await service.store.rebase(batchID:batch.id,stepID:stepID,scope:scope);guard await current() else{return};self.batch=value;message="已保留草稿并更新基线，尚未发送。"}
        catch {message="无法更新基线，请重新打开该标签编辑。"}
    }
    public func websiteURL(setID:String)->URL? { (try? EndpointBuilder().myTags(scope:scope,setID:setID))?.url }
}
