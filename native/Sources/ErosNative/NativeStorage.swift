import Foundation
import UIKit
import ErosServices

extension StorageLayout {
    nonisolated static let production = StorageLayout(
        applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        documents: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
        caches: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0],
        temporary: FileManager.default.temporaryDirectory
    )
}

@MainActor enum NativeProtectedStorage {
    private static var access = ProtectedStorageAccess()

    static var isAvailable: Bool {
        access.permitsAccess(dataAvailable: UIApplication.shared.isProtectedDataAvailable) {
            StorageLayout.production.canReadAfterFirstUnlockFile()
        }
    }
}

enum NativeStoragePhase: Equatable {
    case running
    case waitingForFirstUnlock(resuming: Bool)
    case stopping
    case maintenance
    case migrating(DownloadStorageMigration)
    case reopening
    case stopFailed(String)
    case reopenFailed(String)
}

extension DownloadStorageMigration {
    var buttonTitle: String {
        switch self {
        case .moveToDocuments: "迁移下载到文稿目录"
        case .restorePrivate: "将下载切回私有目录"
        }
    }

    var progressTitle: String {
        switch self {
        case .moveToDocuments: "正在复制并校验下载文件…"
        case .restorePrivate: "正在备份并校验当前下载…"
        }
    }
}

/// The file coordination queue signals the main-actor model through a bounded stream.
final class NativeDownloadFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    let events: AsyncStream<Void>
    private let changes: AsyncStream<Void>.Continuation

    init(directory: URL) {
        presentedItemURL = directory
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        presentedItemOperationQueue = queue
        (events, changes) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        super.init()
    }

    deinit { changes.finish() }
    func presentedItemDidChange() { changes.yield() }
    func presentedItemDidMove(to newURL: URL) { changes.yield() }
    func presentedSubitemDidAppear(at url: URL) { changes.yield() }
    func presentedSubitemDidChange(at url: URL) { changes.yield() }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { changes.yield() }
    func accommodatePresentedItemDeletion(completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        changes.yield()
        completionHandler(nil)
    }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        changes.yield()
        completionHandler(nil)
    }
}
