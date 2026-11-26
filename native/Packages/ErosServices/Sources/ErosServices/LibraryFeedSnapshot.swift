/// A single diffable update may ask for both outgoing and incoming cells.
/// Keep both payloads accessible until UIKit commits the update.
public struct LibraryFeedSnapshot<Row: Identifiable & Equatable> {
    private var displayed: [Row] = []
    private var incoming: [Row]?
    private var byID: [Row.ID: Row] = [:]

    public init() {}
    public var isApplying: Bool { incoming != nil }
    public subscript(id: Row.ID) -> Row? { byID[id] }

    /// Only surviving items whose content changed need reconfiguration.
    public mutating func begin(_ rows: [Row]) -> [Row.ID]? {
        guard incoming == nil, rows != displayed else { return nil }
        var changed: [Row.ID] = []
        for row in rows {
            if let previous = byID.updateValue(row, forKey: row.id), previous != row {
                changed.append(row.id)
            }
        }
        incoming = rows
        return changed
    }

    public mutating func finish() {
        guard let incoming else { return }
        displayed = incoming
        byID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        self.incoming = nil
    }
}
