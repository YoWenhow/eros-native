import Foundation
import ErosCore

extension SQLiteDatabase {
    /// Read once per batch of gallery IDs. This API uses the production Schema 4
    /// slot semantics, including for jobs migrated from an older schema.
    public func galleryDownloadProjections(account: AccountID, galleryIDs: Set<GalleryID>) throws -> [GalleryID: GalleryDownloadProjection] {
        try Task.checkCancellation()
        guard !galleryIDs.isEmpty else { return [:] }
        guard pageSlotsEnabled else { throw PersistenceError.unsupportedSchema }

        let ids = Array(galleryIDs)
        let owner = SQLValue.text(account.value.uuidString)
        let batchSize = 200
        var tasks: [GalleryID: [GalleryDownloadTask]] = [:]
        var missingSlots: Set<GalleryID> = []

        for start in stride(from: 0, to: ids.count, by: batchSize) {
            try Task.checkCancellation()
            let batch = ids[start..<min(start + batchSize, ids.count)]
            let rows = try connection.rows(Self.galleryDownloadProjectionSQL(galleryCount: batch.count),
                                           [owner] + batch.map { .integer($0.value) })
            var archiveKeys: Set<DownloadContentKey> = []
            for row in rows {
                guard case .integer(let rawGallery) = row[0], let gallery = try? GalleryID(rawGallery) else {
                    throw PersistenceError.corruptRecord
                }
                if case .integer(1) = row[8] {
                    missingSlots.insert(gallery)
                    continue
                }
                guard case .text(let rawID) = row[1], let id = UUID(uuidString: rawID),
                      case .text(let rawSite) = row[2], let site = Site(rawValue: rawSite),
                      case .text(let rawSource) = row[3], let source = DownloadSourceKind(rawValue: rawSource),
                      case .text(let rawVariant) = row[4], let variant = DownloadVariant(rawValue: rawVariant),
                      case .text(let rawState) = row[5], let state = DownloadJobState(rawValue: rawState),
                      case .text(let rawGeneration) = row[6], let generation = UInt64(rawGeneration),
                      case .integer(let hasSkippedPages) = row[7] else {
                    throw PersistenceError.corruptRecord
                }
                let key = DownloadContentKey(account: account, gallery: gallery, sourceKind: source, variant: variant)
                // Use the enqueue lookup's lowest-ID ordering if a legacy import had duplicates.
                if source == .archive, !archiveKeys.insert(key).inserted { continue }
                tasks[gallery, default: []].append(GalleryDownloadTask(id: id, contentKey: key, site: site,
                    state: state, generation: generation, hasSkippedPages: hasSkippedPages == 1))
            }
        }
        try Task.checkCancellation()
        var projections = tasks.mapValues { GalleryDownloadProjection(tasks: $0) }
        for gallery in missingSlots {
            projections[gallery] = GalleryDownloadProjection(tasks: tasks[gallery] ?? [], needsPageSlotRecovery: true)
        }
        return projections
    }

    static func galleryDownloadProjectionSQL(galleryCount: Int) -> String {
        let placeholders = Array(repeating: "?", count: galleryCount).joined(separator: ",")
        return """
            SELECT j.gid,j.id,j.site,j.sourceKind,j.variant,j.state,j.generation,
                CASE WHEN j.state='completed' AND (j.sourceKind='archive' OR s.primaryJobID=j.id)
                    THEN EXISTS(SELECT 1 FROM download_pages p WHERE p.jobID=j.id AND p.state='skipped')
                    ELSE 0 END,
                CASE WHEN j.sourceKind='pages' AND s.primaryJobID IS NULL THEN 1 ELSE 0 END
            FROM download_jobs j
            LEFT JOIN download_page_slots s ON j.sourceKind='pages' AND s.account=j.account AND s.gid=j.gid
            WHERE j.account=? AND j.gid IN (\(placeholders))
              AND (j.sourceKind='archive' OR s.primaryJobID=j.id OR s.primaryJobID IS NULL)
            ORDER BY j.gid,j.sourceKind,j.variant,j.id
            """
    }
}

public struct DownloadHealthPageBatch: Sendable {
    public let totalPages: Int
    public let pages: [DownloadPage]
}

extension SQLiteDatabase {
    /// File verification walks the manifest for one exact completed generation.
    /// Only this bounded read decodes page metadata, including any stored digest.
    public func downloadHealthPages(task: GalleryDownloadTask, startingAt: Int) throws -> DownloadHealthPageBatch? {
        try Task.checkCancellation()
        guard task.state == .completed, startingAt >= 0 else { throw AppError.invalidInput }
        let key = task.contentKey
        let rows = try connection.rows("""
            SELECT j.totalPages,p.pageIndex,p.payload
            FROM download_jobs j
            LEFT JOIN download_pages p ON p.jobID=j.id AND p.pageIndex>=?
            WHERE j.id=? AND j.account=? AND j.gid=? AND j.site=? AND j.sourceKind=? AND j.variant=?
              AND j.state='completed' AND j.generation=?
            ORDER BY p.pageIndex LIMIT 16
            """, [.integer(Int64(startingAt)), .text(task.id.uuidString), .text(key.account.value.uuidString),
                .integer(key.gallery.value), .text(task.site.rawValue), .text(key.sourceKind.rawValue),
                .text(key.variant.rawValue), .text(String(task.generation))])
        guard let first = rows.first else { return nil }
        guard case .integer(let count) = first[0], let total = Int(exactly: count), total > 0 else {
            throw PersistenceError.corruptRecord
        }
        let decoder = JSONDecoder()
        let pages = try rows.compactMap { row -> DownloadPage? in
            if case .null = row[1] { return nil }
            guard case .integer(let index) = row[1], case .blob(let data) = row[2],
                  let page = try? decoder.decode(DownloadPage.self, from: data),
                  page.jobID == task.id, page.index.value == index, index < count,
                  page.state == .completed || page.state == .skipped else { throw PersistenceError.corruptRecord }
            return page
        }
        try Task.checkCancellation()
        return DownloadHealthPageBatch(totalPages: total, pages: pages)
    }
}
