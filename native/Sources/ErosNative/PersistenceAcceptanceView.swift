import SwiftUI
import Foundation
import ErosCore
import ErosPersistence

/// Temporary T14 acceptance surface, using an isolated synthetic database.
@MainActor
final class PersistenceAcceptanceModel: ObservableObject {
    @Published var message = "正在只读检查已有验收数据…"
    @Published var receipt = ""
    @Published var canWrite = false
    @Published var busy = false
    private let scope = StorageScope(accountID: AccountID(UUID(uuidString: "00000000-0000-0000-0000-000000000014")!),site: .eh)
    private let jobID = UUID(uuidString: "00000000-0000-0000-0000-000000000014")!
    private var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,in: .userDomainMask)[0]
            .appendingPathComponent("T14Acceptance",isDirectory: true).appendingPathComponent("acceptance.sqlite")
    }
    private func inspect(_ db: SQLiteDatabase) async throws {
        let gid = try GalleryID(14)
        let version = try await db.schemaVersion()
        let gallery = try await db.gallery(galleryID: gid,scope: scope)
        let history = try await SQLiteHistoryStore(database: db).load(galleryID: gid,scope: scope)
        let favorites = try await SQLiteLocalFavoritesStore(database: db).list(scope: scope)
        let download = try await SQLiteDownloadStore(database: db).load(jobID: jobID,scope: scope)
        guard version == 1, let gallery, gallery.title.hasPrefix("T14-"), gallery.pageCount?.value == 3,
              history?.index.value == 1, history?.fraction.value == 0.5,
              favorites.count == 1, favorites[0].summary == gallery,
              download?.job.state == .paused, download?.pages.count == 2,
              download?.pages[0].relativePath?.value == "downloads/t14/0.jpg",
              download?.job.generation == 1 else { throw PersistenceError.corruptRecord }
        receipt = gallery.title
        message = "PASS · schema v1\n历史：第 2 / 3 页，进度 50%\n收藏：1 项，匹配\n下载元数据：2 页、已暂停，相对路径匹配\n仅读已有记录，未重写"
    }
    func check() async {
        guard !busy else { return };busy = true;defer { busy = false }
        canWrite = false
        guard FileManager.default.fileExists(atPath: url.path) else {
            message = "尚无验收数据库。请点击首次写入。";canWrite = true;return
        }
        do {
            let db = try await SQLiteDatabase.open(url: url)
            do { try await inspect(db);await db.close() } catch { await db.close();throw error }
        } catch { message = "FAIL · 读取失败，保留原数据库，未自动重建。" }
    }
    func write() async {
        guard canWrite, !busy else { return };busy = true;canWrite = false;defer { busy = false }
        do {
            // Refuse to overwrite an existing acceptance database, including a partial failed write.
            guard !FileManager.default.fileExists(atPath: url.path) else { throw AppError.invalidInput }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let db = try await SQLiteDatabase.open(url: url)
            do {
                let reference = try GalleryReference(key: GalleryKey(site: .eh,galleryID: GalleryID(14)),token: SensitiveText("synthetic-t14"))
                let gallery = try GallerySummary(reference: reference,title: "T14-" + String(UUID().uuidString.prefix(8)),pageCount: NonnegativeCount(3))
                try await db.saveGallery(gallery,scope: scope)
                try await SQLiteHistoryStore(database: db).save(progress: ReadingProgress(scope: scope,galleryID: reference.key.galleryID,index: PageIndex(1),fraction: UnitFraction(0.5),readingMode: .leftToRight,updatedAt: Date()))
                try await SQLiteLocalFavoritesStore(database: db).save(favorite: LocalFavorite(scope: scope,summary: gallery,savedAt: Date()))
                let job = try DownloadJob(id: jobID,scope: scope,reference: reference,state: .paused,totalPages: NonnegativeCount(2),completedPages: NonnegativeCount(0),generation: 1)
                let pages = try [DownloadPage(jobID: jobID,index: PageIndex(0),state: .pending,relativePath: RelativePath("downloads/t14/0.jpg")),DownloadPage(jobID: jobID,index: PageIndex(1),state: .pending)]
                try await SQLiteDownloadStore(database: db).save(snapshot: DownloadSnapshot(job: job,pages: pages))
                await db.close()
            } catch { await db.close();throw error }
            let reopened = try await SQLiteDatabase.open(url: url)
            do { try await inspect(reopened);await reopened.close() } catch { await reopened.close();throw error }
        } catch { message = "FAIL · 写入/重开验证失败，保留数据库供排查。" }
    }
}

struct PersistenceAcceptanceView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PersistenceAcceptanceModel()
    var body: some View {
        NavigationStack {
            List {
                Section("检查结果") {
                    Text(model.message)
                    if !model.receipt.isEmpty { Text(model.receipt).font(.body.monospaced()).textSelection(.enabled) }
                }
                Section {
                    Button("首次写入验收数据") { Task { await model.write() } }.disabled(!model.canWrite || model.busy)
                    Button("只读复查") { Task { await model.check() } }.disabled(model.busy)
                } footer: {
                    Text("仅使用独立的合成验收数据库。下载项只测试元数据，不下载文件。首次写入后请锁屏返回，再划掉应用重开，确认 PASS 和 T14 值保持不变。")
                }
            }
            .navigationTitle("T14 存储验收")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
            .task { await model.check() }
        }
    }
}
