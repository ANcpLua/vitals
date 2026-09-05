/// Fixed-length CPU history per process identity. One slot per sample, so
/// `capacity` samples at the menu's 2 s tick cover the last 60 s. Unlike the
/// EMA smoother this keeps raw values: a process that spikes to 300% for one
/// sample every 20 s stays visible as a spike for a full window.
///
/// A process that disappears keeps its ring for `grace` further samples
/// (appended as `nil`) so the row can linger dimmed before it drops out.
public struct ProcessCPUHistory: Sendable {
    public struct Identity: Hashable, Sendable {
        public let pid: Int32
        public let ppid: Int32
        public let name: String

        public init(_ process: ProcessView) {
            pid = process.pid
            ppid = process.ppid
            name = process.name
        }
    }

    /// One process's window. `samples` is oldest first, always `capacity`
    /// long; `nil` means no reading (before first sight, or after exit).
    public struct Track: Sendable, Equatable {
        public let last: ProcessView
        public let samples: [Double?]
        public let isAlive: Bool
        public let peak: Double
        public let total: Double
    }

    private struct Ring: Sendable {
        var slots: [Double?]
        var next = 0
        var missing = 0
        var last: ProcessView

        init(capacity: Int, last: ProcessView) {
            slots = Array(repeating: nil, count: capacity)
            self.last = last
        }

        mutating func push(_ value: Double?) {
            slots[next] = value
            next = (next + 1) % slots.count
        }

        var ordered: [Double?] {
            Array(slots[next...] + slots[..<next])
        }
    }

    public let capacity: Int
    public let grace: Int
    private var rings: [Identity: Ring] = [:]

    public init(capacity: Int = 30, grace: Int = 5) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.grace = max(0, grace)
    }

    /// Records one sample for every live process and a `nil` for every
    /// identity that vanished. Identities missing for more than `grace`
    /// samples are dropped.
    public mutating func record(_ processes: [ProcessView]) {
        var seen = Set<Identity>()
        seen.reserveCapacity(processes.count)
        for process in processes {
            let identity = Identity(process)
            seen.insert(identity)
            var ring = rings[identity] ?? Ring(capacity: capacity, last: process)
            ring.push(process.cpuPercent)
            ring.missing = 0
            ring.last = process
            rings[identity] = ring
        }
        for (identity, ring) in rings where !seen.contains(identity) {
            var ring = ring
            ring.missing += 1
            if ring.missing > grace {
                rings.removeValue(forKey: identity)
            } else {
                ring.push(nil)
                rings[identity] = ring
            }
        }
    }

    public func track(_ identity: Identity) -> Track? {
        rings[identity].map(Self.track)
    }

    /// Every tracked identity, ranked by window peak, then window total,
    /// then footprint. Ranking by the window rather than the latest sample
    /// keeps the list from reshuffling on every tick.
    public func tracks() -> [Track] {
        rings.values.map(Self.track).sorted(by: Self.ranked)
    }

    /// Element-wise sum of several identities' windows, for process groups.
    /// A slot is `nil` only when no member has a reading there.
    public func series(_ identities: [Identity]) -> [Double?] {
        var sum = [Double?](repeating: nil, count: capacity)
        for identity in identities {
            guard let ring = rings[identity] else { continue }
            for (index, value) in ring.ordered.enumerated() {
                guard let value else { continue }
                sum[index] = (sum[index] ?? 0) + value
            }
        }
        return sum
    }

    public func peak(_ identities: [Identity]) -> Double {
        series(identities).compactMap { $0 }.max() ?? 0
    }

    public static func ranked(_ lhs: Track, _ rhs: Track) -> Bool {
        guard lhs.peak == rhs.peak else { return lhs.peak > rhs.peak }
        guard lhs.total == rhs.total else { return lhs.total > rhs.total }
        return (lhs.last.footprintBytes ?? 0) > (rhs.last.footprintBytes ?? 0)
    }

    private static func track(_ ring: Ring) -> Track {
        let samples = ring.ordered
        let values = samples.compactMap { $0 }
        return Track(
            last: ring.last,
            samples: samples,
            isAlive: ring.missing == 0,
            peak: values.max() ?? 0,
            total: values.reduce(0, +)
        )
    }
}
