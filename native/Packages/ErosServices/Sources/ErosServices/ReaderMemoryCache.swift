/// A cost-bounded LRU. The owner supplies actual bitmap cost, not compressed size.
public struct ReaderMemoryCache<Key: Hashable, Value> {
    private struct Item { let value: Value; let cost: Int; var tick: UInt64 }
    private var items: [Key: Item] = [:]
    private var tick: UInt64 = 0
    public private(set) var cost = 0
    public var count: Int { items.count }
    public let maximumCost: Int
    public let maximumCount: Int
    public init(maximumCost: Int, maximumCount: Int) {
        self.maximumCost = max(0, maximumCost); self.maximumCount = max(0, maximumCount)
    }
    public mutating func value(for key: Key) -> Value? {
        guard var item = items[key] else { return nil }
        tick &+= 1; item.tick = tick; items[key] = item; return item.value
    }
    public mutating func insert(_ value: Value, for key: Key, cost: Int) {
        remove(key)
        guard cost >= 0, cost <= maximumCost, maximumCount > 0 else { return }
        while self.cost > maximumCost - cost || count >= maximumCount {
            guard let oldest = items.min(by: { $0.value.tick < $1.value.tick })?.key else { break }
            remove(oldest)
        }
        tick &+= 1; items[key] = Item(value: value, cost: cost, tick: tick); self.cost += cost
    }
    public mutating func remove(_ key: Key) { if let old = items.removeValue(forKey: key) { cost -= old.cost } }
    public mutating func retain(where keep: (Key) -> Bool) {
        for key in items.keys.filter({ !keep($0) }) { remove(key) }
    }
    public mutating func clear() { items.removeAll(); cost = 0 }
}
