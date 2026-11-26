import Foundation
import ErosCore

extension VerifiedStorageCopy {
    static func project(_ database: SQLiteConnection, scope: VerifiedCopyScope, owner: AccountID) throws -> [Row] {
        let account = SQLValue.text(owner.value.uuidString)
        switch scope {
        case .downloadFolders:
            let folders = try database.rows("""
                SELECT id,displayName,createdAtMs FROM download_folders WHERE account=? ORDER BY position,id
                """, [account]).map { row in
                let name = try DownloadFolderName(text(row[1]))
                return try Row(.folder, Folder(id: uuid(row[0]), name: name.value, createdAt: integer(row[2])))
            }
            let jobs = try database.rows("""
                SELECT j.id,j.gid,j.site,j.sourceKind,j.variant,i.folderID,i.membershipRevision
                FROM download_jobs j JOIN download_library_items i ON i.jobID=j.id AND i.account=j.account
                WHERE j.account=? ORDER BY j.id
                """, [account]).map { row in
                guard let site = Site(rawValue: try text(row[2])), let kind = DownloadSourceKind(rawValue: try text(row[3])),
                      let variant = DownloadVariant(rawValue: try text(row[4])) else { throw PersistenceError.corruptRecord }
                let folder = try optionalText(row[5]).map { raw in
                    guard let id = UUID(uuidString: raw) else { throw PersistenceError.corruptRecord }
                    return id
                }
                return try Row(.job, Job(id: uuid(row[0]), gid: integer(row[1]), site: site, kind: kind,
                                         variant: variant, folder: folder, membershipRevision: integer(row[6])))
            }
            return folders + jobs
        case .localRules:
            return try database.rows("SELECT id,version,payload FROM local_rules WHERE account=? ORDER BY id", [account]).map { row in
                let rule = try decode(row[2], as: LocalDisplayRule.self)
                guard rule.account == owner, try rule.id == uuid(row[0]), try rule.version == integer(row[1]) else {
                    throw PersistenceError.corruptRecord
                }
                return try Row(.rule, Rule(rule))
            }
        case .imageBlocks:
            return try database.rows("SELECT id,digest,payload FROM image_blocks WHERE owner=? ORDER BY id", [account]).map { row in
                let block = try decode(row[2], as: BlockImageEntry.self)
                guard block.owner == owner, try block.id == uuid(row[0]), try block.digest == text(row[1]) else {
                    throw PersistenceError.corruptRecord
                }
                return try Row(.block, Block(block))
            }
        case .translations:
            let entries = try database.rows("SELECT namespace,original,name,description FROM translations ORDER BY namespace,original")
            guard let value = try database.rows("SELECT payload FROM active_translation WHERE id=1").first else {
                guard entries.isEmpty else { throw PersistenceError.corruptRecord }
                return []
            }
            let installation = try decode(value[0], as: TranslationInstallation.self)
            guard entries.count == installation.entryCount, !entries.isEmpty else { throw PersistenceError.corruptRecord }
            return [try Row(.installation, installation)] + (try entries.map { row in
                let entry = try Translation(namespace: text(row[0]), original: text(row[1]), name: text(row[2]),
                                            description: optionalText(row[3]))
                _ = try entry.model()
                return try Row(.translation, entry)
            })
        }
    }

    static func apply(_ rows: [Row], to database: SQLiteConnection, scope: VerifiedCopyScope,
                      owner: AccountID) throws -> VerifiedCopyImport {
        if scope == .translations { return try restoreTranslation(rows, database: database) }
        let account = SQLValue.text(owner.value.uuidString)
        var result = VerifiedCopyImport()
        var knownFolders: Set<UUID> = []
        for row in rows {
            try Task.checkCancellation()
            switch row.kind {
            case .folder:
                let folder = try row.decode(Folder.self)
                if try restoreFolder(folder, account: account, database: database, result: &result) {
                    knownFolders.insert(folder.id)
                }
            case .job:
                try restoreJobFolder(row.decode(Job.self), account: account, knownFolders: knownFolders, database: database, result: &result)
            case .rule:
                let rule = try row.decode(Rule.self).model(owner: owner)
                let key = [account, .text(rule.id.uuidString)]
                if let current = try database.rows("SELECT payload FROM local_rules WHERE account=? AND id=?", key).first {
                    guard try decode(current[0], as: LocalDisplayRule.self) == rule else {
                        result.pending.append(rule.id.uuidString)
                        continue
                    }
                } else {
                    try database.execute("INSERT INTO local_rules VALUES(?,?,?,?)", key + [.integer(Int64(rule.version)), blob(rule)])
                    result.inserted += 1
                }
            case .block:
                let entry = try row.decode(Block.self).model(owner: owner)
                let rows = try database.rows("SELECT id,digest FROM image_blocks WHERE owner=? AND (id=? OR digest=?)",
                                             [account, .text(entry.id.uuidString), .text(entry.digest)])
                if rows.isEmpty {
                    try database.execute("INSERT INTO image_blocks VALUES(?,?,?,?)",
                                         [account, .text(entry.digest), .text(entry.id.uuidString), blob(entry)])
                    result.inserted += 1
                } else if try !rows.contains(where: { try uuid($0[0]) == entry.id && text($0[1]) == entry.digest }) {
                    result.pending.append(entry.id.uuidString)
                }
            case .installation, .translation:
                throw PersistenceError.corruptRecord
            }
        }
        return result
    }

    private static func restoreFolder(_ folder: Folder, account: SQLValue, database: SQLiteConnection,
                                      result: inout VerifiedCopyImport) throws -> Bool {
        let id = SQLValue.text(folder.id.uuidString)
        let name = try DownloadFolderName(folder.name)
        let current = try database.rows("SELECT id,displayName FROM download_folders WHERE account=? AND (id=? OR normalizedName=?)",
                                        [account, id, .text(name.normalizedName)])
        if !current.isEmpty {
            if try current.contains(where: { try uuid($0[0]) == folder.id && text($0[1]) == folder.name }) { return true }
            result.pending.append(folder.id.uuidString)
            return false
        }
        let last = try integer(database.rows("SELECT COALESCE(MAX(position),-1) FROM download_folders WHERE account=?", [account])[0][0])
        guard last < Int64.max else { throw PersistenceError.corruptRecord }
        try database.execute("INSERT INTO download_folders VALUES(?,?,?,?,?,?,?,1)",
                             [account, id, .text(name.value), .text(name.normalizedName), .integer(last + 1),
                              .integer(folder.createdAt), .integer(folder.createdAt)])
        result.inserted += 1
        return true
    }

    private static func restoreJobFolder(_ job: Job, account: SQLValue, knownFolders: Set<UUID>, database: SQLiteConnection,
                                         result: inout VerifiedCopyImport) throws {
        let key = [account, .text(job.id.uuidString)]
        guard let current = try database.rows("""
            SELECT j.gid,j.site,j.sourceKind,j.variant,i.folderID,i.membershipRevision
            FROM download_jobs j JOIN download_library_items i ON i.jobID=j.id AND i.account=j.account
            WHERE j.account=? AND j.id=?
            """, key).first,
            try integer(current[0]) == job.gid, try text(current[1]) == job.site.rawValue,
            try text(current[2]) == job.kind.rawValue, try text(current[3]) == job.variant.rawValue else {
            result.pending.append(job.id.uuidString)
            return
        }
        let currentFolder = try optionalText(current[4])
        if currentFolder == job.folder?.uuidString { return }
        guard currentFolder == nil, let folder = job.folder,
              try integer(current[5]) == job.membershipRevision, job.membershipRevision < Int64.max,
              knownFolders.contains(folder) else {
            result.pending.append(job.id.uuidString)
            return
        }
        try database.execute("UPDATE download_library_items SET folderID=?, membershipRevision=membershipRevision+1 WHERE account=? AND jobID=?",
                             [.text(folder.uuidString)] + key)
        result.inserted += 1
    }

    private static func restoreTranslation(_ rows: [Row], database: SQLiteConnection) throws -> VerifiedCopyImport {
        guard !rows.isEmpty else { return VerifiedCopyImport() }
        guard let first = rows.first, first.kind == .installation, rows.dropFirst().allSatisfy({ $0.kind == .translation }) else {
            throw PersistenceError.corruptRecord
        }
        let installation = try first.decode(TranslationInstallation.self)
        let entries = try rows.dropFirst().map { try $0.decode(Translation.self).model() }
        guard !entries.isEmpty, entries.count == installation.entryCount else { throw PersistenceError.corruptRecord }
        _ = try TagTranslationEntry.index(entries)
        if let active = try database.rows("SELECT payload FROM active_translation WHERE id=1").first {
            let current = try decode(active[0], as: TranslationInstallation.self)
            return VerifiedCopyImport(pending: current.hash == installation.hash && current.version == installation.version ? [] : ["词库版本"])
        }
        guard try database.rows("SELECT 1 FROM translations LIMIT 1").isEmpty else {
            return VerifiedCopyImport(pending: ["词库记录"])
        }
        for entry in entries {
            try Task.checkCancellation()
            try database.execute("INSERT INTO translations VALUES(?,?,?,?)",
                                 [.text(entry.key.namespace), .text(entry.key.original), .text(entry.localizedText),
                                  entry.description.map(SQLValue.text) ?? .null])
        }
        try database.execute("INSERT INTO active_translation VALUES(1,?)", [blob(installation)])
        return VerifiedCopyImport(inserted: entries.count)
    }
}
