import BackgroundTasks
import ErosCore
import ErosServices
import Foundation
import UIKit

enum NativeDownloadContinuation {
    static let scheduler = DownloadContinuationScheduler(
        submit: { id, launch in try await submit(id: id, launch: launch) },
        cancel: { id in BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier(id)) }
    )

    private static func identifier(_ id: UUID) -> String {
        "\(Bundle.main.bundleIdentifier ?? "org.erosnative.app").downloads.continued.\(id.uuidString)"
    }

    @MainActor
    private static func submit(id: UUID, launch: @escaping DownloadContinuationScheduler.Launch) async throws {
        guard UIApplication.shared.applicationState == .active, !PrivacyController.shared.locked else {
            throw AppError.staleSession
        }
        let name = identifier(id)
        guard BGTaskScheduler.shared.register(forTaskWithIdentifier: name, using: nil, launchHandler: { @Sendable task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let handle = NativeDownloadContinuationTask(task)
            launch(DownloadContinuationTask(installExpiration: handle.installExpiration,
                                             report: handle.report, finish: handle.finish))
        }) else {
            throw AppError.accessDenied
        }
        let request = BGContinuedProcessingTaskRequest(identifier: name, title: "下载进行中", subtitle: "正在处理下载")
        request.strategy = .fail
        try await submitRequest(request)
    }

    // iOS 27 delivers the submission result asynchronously on its own queue.
    @concurrent
    private static func submitRequest(_ request: BGContinuedProcessingTaskRequest) async throws {
        try await BGTaskScheduler.shared.submitTaskRequest(request)
    }
}

/// The SDK hands a non-Sendable BGTask to its launch callback. After that
/// callback hands it to this object, the lock serializes all app access.
private final class NativeDownloadContinuationTask: @unchecked Sendable {
    private let lock = NSLock()
    private var task: BGContinuedProcessingTask?
    private var latest: DownloadContinuationProgress?
    private var published: DownloadContinuationProgress?
    private var lastUpdate: ContinuousClock.Instant?

    init(_ task: BGContinuedProcessingTask) { self.task = task }

    func installExpiration(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { task?.expirationHandler = handler }
    }

    func report(_ progress: DownloadContinuationProgress) {
        lock.withLock {
            guard let task else { return }
            latest = progress
            let now = ContinuousClock.now
            let stateChanged = published.map {
                $0.running != progress.running || $0.completed != progress.completed || $0.paused != progress.paused
                    || $0.failed != progress.failed || $0.waiting != progress.waiting || $0.archivePhase != progress.archivePhase
            } ?? true
            guard stateChanged || lastUpdate.map({ $0.duration(to: now) >= .seconds(2) }) == true else { return }
            published = progress
            lastUpdate = now
            apply(progress, to: task)
            task.updateTitle("下载进行中", subtitle: subtitle(progress))
        }
    }

    private func apply(_ progress: DownloadContinuationProgress, to task: BGContinuedProcessingTask) {
        task.progress.totalUnitCount = progress.totalPages
        task.progress.completedUnitCount = progress.processedPages
    }

    private func subtitle(_ progress: DownloadContinuationProgress) -> String {
        let pages = "已处理 \(progress.processedPages)/\(progress.totalPages) 页"
        switch progress.archivePhase {
        case .preparation: return "正在准备归档 · " + pages
        case .file: return "正在下载归档 · " + pages
        case .importFiles: return "正在校验与解包 · " + pages
        case .completion: return "正在保存归档 · " + pages
        case nil:
            return "完成 \(progress.completed)/\(progress.totalJobs) 项 · " + pages
        }
    }

    func finish(_ succeeded: Bool) {
        lock.withLock {
            guard let current = task else { return }
            task = nil
            if let latest {
                apply(latest, to: current)
                current.updateTitle(succeeded ? "下载完成" : "下载已停止",
                                    subtitle: "已处理 \(latest.processedPages)/\(latest.totalPages) 页")
            }
            current.setTaskCompleted(success: succeeded)
        }
    }
}
