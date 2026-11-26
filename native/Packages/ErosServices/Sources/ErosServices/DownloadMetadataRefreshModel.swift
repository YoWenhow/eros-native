import Foundation
import Observation
import ErosCore

/// A sheet owns one explicit batch. Preparing and reopening never send network requests.
@MainActor @Observable public final class DownloadMetadataRefreshModel {
    public private(set) var plan: DownloadMetadataRefreshPlan?
    public private(set) var progress: DownloadMetadataRefreshProgress?
    public private(set) var preparing=false
    public private(set) var running=false
    public private(set) var cancelling=false
    public private(set) var error: String?
    public let refreshKnown: Bool
    public private(set) var batchSize: DownloadMetadataBatchSize = .fifty
    public var nextBatchCount: Int {
        guard let plan, let progress, progress.stop != .staleSession else { return 0 }
        return plan.deferredCount + progress.remaining + progress.cancelled
    }
    private var pendingJobIDs: Set<UUID>
    private let scope: SessionScope
    private let service: DownloadMetadataRefreshService
    private var task: Task<Void,Never>?
    private var closed=false
    public init(jobIDs:Set<UUID>,scope:SessionScope,service:DownloadMetadataRefreshService,refreshKnown:Bool=false) {
        pendingJobIDs=jobIDs; self.scope=scope; self.service=service; self.refreshKnown=refreshKnown
    }
    public func selectBatchSize(_ size: DownloadMetadataBatchSize) {
        guard !refreshKnown, !closed, !preparing, !running, progress == nil else { return }
        batchSize = size
        plan?.batchSize = size
    }
    public func prepareNextBatch() async {
        guard !closed, !running, !preparing, let plan, let progress, nextBatchCount > 0 else { return }
        let attempted = progress.succeeded + progress.failed
        pendingJobIDs = Set(plan.jobIDs.dropFirst(attempted)).union(plan.deferredJobIDs)
        self.progress=nil
        await prepare()
    }
    public func prepare() async {
        guard !closed, !preparing, !running, progress == nil else { return }
        preparing=true; error=nil; plan=nil
        defer { preparing=false }
        do {
            let value=try await service.prepare(jobIDs:pendingJobIDs,scope:scope,refreshKnown:refreshKnown,batchSize:batchSize)
            try Task.checkCancellation()
            if !closed { plan=value }
        } catch is CancellationError {} catch {
            if !closed { self.error="无法准备批次。任务或会话可能已变化，请重新打开。" }
        }
    }
    public func start() {
        guard !closed, !running, !preparing, progress == nil, let plan, plan.total > 0 else { return }
        running=true; cancelling=false; error=nil
        task=Task { [weak self,service] in
            do {
                let result=try await service.run(plan) { [weak self] value in
                    await self?.receive(value)
                }
                self?.receive(result)
            } catch {
                if self?.closed == false { self?.error="另一批可能仍在结束，请稍后重试。" }
            }
            self?.running=false; self?.cancelling=false; self?.task=nil
        }
    }
    private func receive(_ value:DownloadMetadataRefreshProgress) {
        if !closed { progress=value }
    }
    public func cancel() {
        guard running else { return }
        cancelling=true
        // Cancel only this sheet's operation, never a different caller's shared service task.
        task?.cancel()
    }
    public func close() { closed=true; task?.cancel() }
    isolated deinit { task?.cancel() }
}

/// Raw display value corresponding to the existing normalized sort key.
public enum DownloadMetadataPresentation {
    public static func timestamp(_ value:DownloadLibraryTimestamp?,timeZone:TimeZone = .current) -> String {
        guard let value else { return "未知" }
        let formatter=DateFormatter()
        formatter.locale=Locale(identifier:"en_US_POSIX")
        formatter.calendar=Calendar(identifier:.gregorian)
        formatter.timeZone=timeZone
        formatter.dateFormat="yyyy-MM-dd HH:mm:ss"
        return formatter.string(from:Date(timeIntervalSince1970:Double(value.value)/1000))
    }
    public static func summary(_ tags:[String],state:DownloadMetadataState) -> String {
        guard state == .complete else { return "待补全" }
        guard let key=DownloadLibraryText.primaryTag(tags),
              let primary=tags.first(where:{DownloadLibraryText.normalizedTag($0) == key}) else { return "未标注" }
        let count=Set(tags.compactMap(DownloadLibraryText.normalizedTag)).count
        return count > 1 ? "\(primary) 等 \(count) 个" : primary
    }
}
