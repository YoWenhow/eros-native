import Foundation
import ErosCore

/// Public translation catalog, separate from private galleries/downloads and their schema.
public actor TranslationStore {
    private let connection: SQLiteConnection
    public init(url: URL, storageLease: StorageLease? = nil) throws {
        try storageLease?.check()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        connection = try SQLiteConnection(path: url.path, migrations: [Migration(version:1,statements:[
            "CREATE TABLE translations(namespace TEXT NOT NULL, original TEXT NOT NULL, name TEXT NOT NULL, description TEXT, PRIMARY KEY(namespace,original)) WITHOUT ROWID",
            "CREATE TABLE active_translation(id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL)"
        ])], storageLease: storageLease)
    }
    public func checkpointAndClose() throws { try connection.checkpointAndClose() }
    public func installation() throws -> TranslationInstallation? {
        guard let row=try connection.rows("SELECT payload FROM active_translation WHERE id=1").first,
              case .blob(let data)=row[0] else { return nil }
        return try JSONDecoder().decode(TranslationInstallation.self,from:data)
    }
    public func entry(for key: TagTranslationKey) throws -> TagTranslationEntry? {
        guard let row=try connection.rows("SELECT name,description FROM translations WHERE namespace=? AND original=?",[.text(key.namespace),.text(key.original)]).first,
              case .text(let name)=row[0] else { return nil }
        let description:String?; if case .text(let value)=row[1] { description=value } else { description=nil }
        return try TagTranslationEntry(namespace:key.namespace,original:key.original,localizedText:name,description:description)
    }
    /// One actor turn returns labels and attribution from the same committed version.
    public func snapshot(for keys:[TagTranslationKey]) throws -> TranslationReadSnapshot {
        guard keys.count <= 512 else { throw AppError.invalidInput }
        var entries=[TagTranslationKey:TagTranslationEntry]()
        for key in Set(keys) { if let value=try entry(for:key) { entries[key]=value } }
        return TranslationReadSnapshot(installation:try installation(),entries:entries)
    }
    public func suggestions(text:String,limit:Int=30) throws -> [TagTranslationEntry] {
        let (namespace,term)=SearchAssistance.lookupParts(text)
        guard !term.isEmpty,term.count<=256 else { return [] }
        try Task.checkCancellation()
        let simplified = term.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? term
        let traditional = term.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? term
        let variants = Array(Set([term, simplified, traditional])).sorted()
        let translatedMatches = variants.map { _ in "instr(name,?)>0" }.joined(separator: " OR ")
        let sql = "SELECT namespace,original,name FROM translations WHERE (? IS NULL OR namespace=?) AND (instr(lower(original),lower(?))>0 OR " + translatedMatches + ") ORDER BY CASE WHEN lower(original)=lower(?) OR name=? THEN 0 WHEN instr(lower(original),lower(?))=1 OR instr(name,?)=1 THEN 1 ELSE 2 END,namespace,original LIMIT ?"
        let ns = namespace.map(SQLValue.text) ?? .null
        let parameters: [SQLValue] = [ns, ns, .text(term)] + variants.map(SQLValue.text) +
            [.text(term), .text(term), .text(term), .text(term), .integer(Int64(max(1,min(limit,50))))]
        let rows = try connection.rows(sql, parameters)
        try Task.checkCancellation()
        return try rows.compactMap { row in
            guard case .text(let ns)=row[0],case .text(let original)=row[1],case .text(let name)=row[2] else { return nil }
            return try TagTranslationEntry(namespace:ns,original:original,localizedText:name)
        }
    }
    public func displayName(namespace:String, original:String) throws -> String {
        guard let key=try? TagTranslationKey(namespace:namespace,original:original) else { return original }
        return try entry(for:key)?.localizedText ?? original
    }
    public func replace(with dataset:TranslationDataset) throws { try replace(with:dataset, checkpoint:{}) }
    // Injection point for rollback/cancellation/full-disk tests; no user-facing bypass.
    func replace(with dataset:TranslationDataset, checkpoint:() throws -> Void) throws {
        guard !dataset.entries.isEmpty, dataset.entries.count==dataset.installation.entryCount else { throw PersistenceError.corruptRecord }
        try connection.transaction {
            try Task.checkCancellation()
            try connection.execute("DELETE FROM translations")
            for entry in dataset.entries {
                try Task.checkCancellation(); try checkpoint()
                try connection.execute("INSERT INTO translations(namespace,original,name,description) VALUES (?,?,?,?)",[.text(entry.key.namespace),.text(entry.key.original),.text(entry.localizedText),entry.description.map(SQLValue.text) ?? .null])
            }
            try connection.execute("INSERT OR REPLACE INTO active_translation(id,payload) VALUES (1,?)",[.blob(try JSONEncoder().encode(dataset.installation))])
            try checkpoint(); try Task.checkCancellation()
            // COMMIT is the publish point: cancellation after this point cannot undo a published version.
        }
    }
}
