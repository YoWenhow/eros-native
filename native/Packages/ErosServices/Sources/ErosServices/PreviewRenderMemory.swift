import Observation

/// Shared decoded previews. Eviction clears the observable slot even if an
/// offscreen SwiftUI cell still retains it, so cell state cannot bypass the cap.
@MainActor public final class PreviewRenderMemory<Key: Hashable, Value> {
    @Observable public final class Entry {
        public fileprivate(set) var value: Value?
        fileprivate init() {}
    }
    private final class WeakEntry {
        weak var entry: Entry?
        init(_ entry: Entry) { self.entry = entry }
    }
    private struct Item { let entry: Entry; let cost: Int; var tick: UInt64 }
    private var registry: [Key: WeakEntry] = [:]
    private var items: [Key: Item] = [:]
    private var tick: UInt64 = 0
    private var createdSincePrune = 0
    public private(set) var cost = 0
    public var count: Int { items.count }
    private let maximumCost: Int
    private let maximumCount: Int
    public init(maximumCost: Int, maximumCount: Int) {
        self.maximumCost = max(0, maximumCost); self.maximumCount = max(0, maximumCount)
    }
    public func entry(for key: Key) -> Entry {
        if let entry = registry[key]?.entry { return entry }
        createdSincePrune += 1
        if createdSincePrune >= 128 {
            registry = registry.filter { $0.value.entry != nil }; createdSincePrune = 0
        }
        let entry = Entry(); registry[key] = WeakEntry(entry); return entry
    }
    public func touch(_ key: Key) {
        guard var item = items[key] else { return }
        tick &+= 1; item.tick = tick; items[key] = item
    }
    public func insert(_ value: Value, for key: Key, cost: Int) {
        remove(key)
        guard cost >= 0, cost <= maximumCost, maximumCount > 0 else { return }
        while self.cost > maximumCost - cost || count >= maximumCount {
            guard let oldest = items.min(by: { $0.value.tick < $1.value.tick })?.key else { break }
            remove(oldest)
        }
        let entry = entry(for: key)
        tick &+= 1; items[key] = Item(entry: entry, cost: cost, tick: tick)
        self.cost += cost; entry.value = value
    }
    public func remove(_ key: Key) {
        if let item = items.removeValue(forKey: key) { cost -= item.cost; item.entry.value = nil }
    }
    public func clear() {
        for item in items.values { item.entry.value = nil }
        items.removeAll(); cost = 0
        registry = registry.filter { $0.value.entry != nil }
    }
}
