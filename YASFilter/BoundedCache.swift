import Foundation

/// A dictionary with a fixed capacity that evicts the oldest inserted key when full.
///
/// Used for per-flow and per-process state in the filter path, where a missed
/// cleanup (a flow that never reports closed, a process that exits) must not grow
/// memory without bound. Not thread-safe; wrap it in a lock.
struct BoundedCache<Key: Hashable, Value> {
    let capacity: Int
    private var storage: [Key: (value: Value, sequence: UInt64)] = [:]
    /// Insertion order. Entries whose sequence no longer matches `storage` are stale
    /// (the key was removed, or removed and re-inserted) and are skipped.
    private var order: [(key: Key, sequence: UInt64)] = []
    private var head = 0
    private var nextSequence: UInt64 = 0

    init(capacity: Int) {
        precondition(capacity > 0, "BoundedCache capacity must be positive")
        self.capacity = capacity
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }
    var keys: [Key] { Array(storage.keys) }

    subscript(key: Key) -> Value? {
        get { storage[key]?.value }
        set {
            if let newValue { insert(newValue, for: key) } else { removeValue(for: key) }
        }
    }

    /// Inserts or replaces. Replacing keeps the key's original age.
    mutating func insert(_ value: Value, for key: Key) {
        if let existing = storage[key] {
            storage[key] = (value, existing.sequence)
            return
        }
        let sequence = nextSequence
        nextSequence += 1
        storage[key] = (value, sequence)
        order.append((key, sequence))
        while storage.count > capacity {
            evictOldest()
        }
        compactIfNeeded()
    }

    @discardableResult
    mutating func removeValue(for key: Key) -> Value? {
        let removed = storage.removeValue(forKey: key)?.value
        compactIfNeeded()
        return removed
    }

    mutating func removeAll() {
        storage.removeAll()
        order.removeAll()
        head = 0
    }

    private mutating func evictOldest() {
        while head < order.count {
            let entry = order[head]
            head += 1
            if storage[entry.key]?.sequence == entry.sequence {
                storage.removeValue(forKey: entry.key)
                return
            }
        }
    }

    /// Drops consumed and stale entries from `order` once they outnumber live keys.
    private mutating func compactIfNeeded() {
        guard order.count - head > max(2 * capacity, 64) || head > max(capacity, 64) else { return }
        let live = storage
        order = order[head...].filter { live[$0.key]?.sequence == $0.sequence }
        head = 0
    }
}

extension BoundedCache: Sendable where Key: Sendable, Value: Sendable {}
