import ErosServices

enum NativeDownloadRecovery {
    static let production = make(layout: .production)

    static func make(layout: StorageLayout) -> BackgroundDownloadRecovery {
        BackgroundDownloadRecovery(layout: layout, validateImage: { try DownloadImageValidation.validate($0) }) { generation in
            let background = BackgroundDownloads.shared
            let lease = generation.storage.lease
            try await background.reconcile(generation: generation)
            try lease.check()
            background.installReceiptRoute(BackgroundReceiptRoute(lease: lease) { ticket, bytes in
                _ = try await generation.receipts.accept(ticket: ticket, bytes: bytes)
                background.acknowledge(ticket, lease: lease)
            })
        }
    }

    @MainActor static func wakeIfAvailable() {
        guard NativeProtectedStorage.isAvailable else { return }
        Task { _ = try? await production.prepare(protectedStorageAvailable: true) }
    }
}
