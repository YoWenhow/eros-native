import Foundation
import ErosCore

/// One scope per file and per restore transaction. The public schema is independent of the running databases.
public enum VerifiedCopyScope: String, CaseIterable, Codable, Identifiable, Sendable {
    case downloadFolders, localRules, imageBlocks, translations
    public var id: Self { self }
    var sourceVersion: Int { self == .downloadFolders ? 4 : 1 }
}

public struct VerifiedCopyHeader: Codable, Equatable, Sendable {
    public let format: Int
    public let id: UUID
    public let scope: VerifiedCopyScope
    public let generatedAt: Date
    public let sourceRevision: String
    public let rowCount: Int
}

public struct VerifiedCopyImport: Equatable, Sendable {
    public internal(set) var inserted = 0
    public internal(set) var pending: [String] = []
}

public enum VerifiedStorageCopy {
    enum Kind: String, Codable, Sendable { case folder, job, rule, block, installation, translation }
    struct Row: Codable, Sendable {
        let kind: Kind
        let payload: String

        init(_ kind: Kind, _ value: some Encodable) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            self.kind = kind
            payload = String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        init(_ kind: Kind, payload: String) {
            self.kind = kind
            self.payload = payload
        }
        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            try JSONDecoder().decode(type, from: Data(payload.utf8))
        }
    }

    struct Folder: Codable { let id: UUID; let name: String; let createdAt: Int64 }
    struct Job: Codable {
        let id: UUID; let gid: Int64; let site: Site; let kind: DownloadSourceKind; let variant: DownloadVariant
        let folder: UUID?; let membershipRevision: Int64
    }
    struct Rule: Codable {
        let id: UUID; let version: Int; let createdAt: Date; let kind: LocalRuleKind
        let enabled: Bool; let namespace: String?; let value: String

        init(_ rule: LocalDisplayRule) {
            id = rule.id; version = rule.version; createdAt = rule.createdAt; kind = rule.kind
            enabled = rule.enabled; namespace = rule.namespace; value = rule.value
        }
        func model(owner: AccountID) throws -> LocalDisplayRule {
            try LocalDisplayRule(id: id, account: owner, version: version, createdAt: createdAt,
                                 enabled: enabled, kind: kind, namespace: namespace, value: value)
        }
    }
    struct Block: Codable {
        let id: UUID; let algorithm: Int; let digest: String; let createdAt: Date
        init(_ entry: BlockImageEntry) {
            id = entry.id; algorithm = entry.algorithmVersion; digest = entry.digest; createdAt = entry.createdAt
        }
        func model(owner: AccountID) throws -> BlockImageEntry {
            try BlockImageEntry(id: id, owner: owner, algorithmVersion: algorithm, digest: digest, createdAt: createdAt)
        }
    }
    struct Translation: Codable {
        let namespace: String; let original: String; let name: String; let description: String?
        func model() throws -> TagTranslationEntry {
            try TagTranslationEntry(namespace: namespace, original: original, localizedText: name, description: description)
        }
    }

    private static let schema = [Migration(version: 1, statements: [
        "CREATE TABLE copy_info(id INTEGER PRIMARY KEY CHECK(id=1), manifest TEXT NOT NULL)",
        "CREATE TABLE copy_rows(position INTEGER PRIMARY KEY, kind TEXT NOT NULL, payload TEXT NOT NULL)"
    ])]

    public static func create(source: URL, snapshot: URL, copy: URL, scope: VerifiedCopyScope,
                              owner: AccountID, id: UUID) throws -> VerifiedCopyHeader {
        try SQLiteConnection.makeSnapshot(from: source, to: snapshot, version: scope.sourceVersion)
        let frozen = try SQLiteConnection.readSnapshot(at: snapshot, version: scope.sourceVersion)
        defer { frozen.close() }
        let rows = try project(frozen, scope: scope, owner: owner)
        let header = VerifiedCopyHeader(format: 1, id: id, scope: scope, generatedAt: Date(),
                                        sourceRevision: try revision(rows), rowCount: rows.count)
        // A fresh standalone projection can use a rollback journal throughout.
        let database = try SQLiteConnection(path: copy.path, migrations: schema, journalMode: .delete)
        defer { database.close() }
        try database.transaction {
            try database.execute("INSERT INTO copy_info VALUES(1,?)",
                                 [.text(String(decoding: try JSONEncoder().encode(header), as: UTF8.self))])
            for (offset, row) in rows.enumerated() {
                try Task.checkCancellation()
                try database.execute("INSERT INTO copy_rows VALUES(?,?,?)",
                                     [.integer(Int64(offset)), .text(row.kind.rawValue), .text(row.payload)])
            }
        }
        database.close()
        _ = try checkedRows(copy, header: header)
        return header
    }

    /// The caller admits only exact bytes from its private export registry, copied into isolation.
    public static func restore(copy: URL, header: VerifiedCopyHeader, destination: URL, archive: URL,
                               owner: AccountID) throws -> VerifiedCopyImport {
        let rows = try checkedRows(copy, header: header)
        if header.scope == .downloadFolders {
            let journal = try SQLiteConnection.readSnapshot(at: archive, version: 1)
            journal.close()
        }
        let database = try SQLiteConnection.openForMaintenance(at: destination, version: header.scope.sourceVersion)
        defer { database.close() }
        return try database.transaction {
            let result = try apply(rows, to: database, scope: header.scope, owner: owner)
            try Task.checkCancellation()
            return result
        }
    }

    private static func checkedRows(_ url: URL, header: VerifiedCopyHeader) throws -> [Row] {
        let database = try SQLiteConnection.readSnapshot(at: url, version: 1)
        defer { database.close() }
        let objects = try database.rows("SELECT name FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY name")
        guard try objects.map({ try text($0[0]) }) == ["copy_info", "copy_rows", "schema_migrations"],
              let info = try database.rows("SELECT manifest FROM copy_info WHERE id=1").first,
              try JSONDecoder().decode(VerifiedCopyHeader.self, from: Data(text(info[0]).utf8)) == header,
              header.format == 1 else { throw PersistenceError.corruptRecord }
        let rows = try database.rows("SELECT kind,payload FROM copy_rows ORDER BY position").map { item in
            guard let kind = Kind(rawValue: try text(item[0])), allowed(kind, in: header.scope) else {
                throw PersistenceError.corruptRecord
            }
            return Row(kind, payload: try text(item[1]))
        }
        guard rows.count == header.rowCount, try revision(rows) == header.sourceRevision else {
            throw PersistenceError.corruptRecord
        }
        return rows
    }

    private static func allowed(_ kind: Kind, in scope: VerifiedCopyScope) -> Bool {
        switch scope {
        case .downloadFolders: kind == .folder || kind == .job
        case .localRules: kind == .rule
        case .imageBlocks: kind == .block
        case .translations: kind == .installation || kind == .translation
        }
    }

    static func text(_ value: SQLValue) throws -> String {
        guard case .text(let result) = value else { throw PersistenceError.corruptRecord }
        return result
    }
    static func integer(_ value: SQLValue) throws -> Int64 {
        guard case .integer(let result) = value else { throw PersistenceError.corruptRecord }
        return result
    }
    static func uuid(_ value: SQLValue) throws -> UUID {
        guard let result = UUID(uuidString: try text(value)) else { throw PersistenceError.corruptRecord }
        return result
    }
    static func optionalText(_ value: SQLValue) throws -> String? {
        if case .null = value { return nil }
        return try text(value)
    }
    static func decode<T: Decodable>(_ value: SQLValue, as type: T.Type) throws -> T {
        guard case .blob(let data) = value else { throw PersistenceError.corruptRecord }
        return try JSONDecoder().decode(type, from: data)
    }
    static func blob(_ value: some Encodable) throws -> SQLValue { .blob(try JSONEncoder().encode(value)) }

    private static func revision(_ rows: [Row]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return TranslationDigest.sha256(try encoder.encode(rows))
    }
}
