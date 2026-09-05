/// Cumulative byte counters for one process, as reported by `nettop`.
public struct NetworkCounters: Sendable, Equatable {
    public let bytesIn: UInt64
    public let bytesOut: UInt64

    public init(bytesIn: UInt64, bytesOut: UInt64) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

public struct NetworkFrame: Sendable, Equatable {
    public let monotonicNanos: UInt64
    public let counters: [Int32: NetworkCounters]

    public init(monotonicNanos: UInt64, counters: [Int32: NetworkCounters]) {
        self.monotonicNanos = monotonicNanos
        self.counters = counters
    }
}

/// Bytes per second over the interval between two frames.
public struct NetworkRate: Sendable, Equatable {
    public let inPerSecond: Double
    public let outPerSecond: Double

    public init(inPerSecond: Double, outPerSecond: Double) {
        self.inPerSecond = inPerSecond
        self.outPerSecond = outPerSecond
    }

    public var total: Double { inPerSecond + outPerSecond }

    public static func + (lhs: NetworkRate, rhs: NetworkRate) -> NetworkRate {
        NetworkRate(
            inPerSecond: lhs.inPerSecond + rhs.inPerSecond,
            outPerSecond: lhs.outPerSecond + rhs.outPerSecond
        )
    }
}

public enum Network {
    /// Parses `nettop -P -L 1 -J bytes_in,bytes_out` output:
    /// a header line, then `name.pid,bytes_in,bytes_out,` per process. The
    /// process name may itself contain dots, so the pid is the last
    /// dot-separated component of the first field.
    public static func parse(_ text: String) -> [Int32: NetworkCounters] {
        var counters: [Int32: NetworkCounters] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let pidText = fields[0].split(separator: ".").last,
                  let pid = Int32(pidText), pid > 0,
                  let bytesIn = UInt64(fields[1]),
                  let bytesOut = UInt64(fields[2])
            else { continue }
            counters[pid] = NetworkCounters(bytesIn: bytesIn, bytesOut: bytesOut)
        }
        return counters
    }

    /// Per-process deltas between two frames as bytes per second. A pid
    /// whose counter went backwards (pid reuse, nettop restart) is dropped
    /// for this interval rather than reported as a huge negative burst.
    public static func rates(previous: NetworkFrame, current: NetworkFrame) -> [Int32: NetworkRate] {
        guard current.monotonicNanos > previous.monotonicNanos else { return [:] }
        let seconds = Double(current.monotonicNanos - previous.monotonicNanos) / 1_000_000_000
        var rates: [Int32: NetworkRate] = [:]
        for (pid, now) in current.counters {
            guard let before = previous.counters[pid],
                  now.bytesIn >= before.bytesIn, now.bytesOut >= before.bytesOut
            else { continue }
            rates[pid] = NetworkRate(
                inPerSecond: Double(now.bytesIn - before.bytesIn) / seconds,
                outPerSecond: Double(now.bytesOut - before.bytesOut) / seconds
            )
        }
        return rates
    }

    /// Sum of the members' rates; `nil` when no member had a reading.
    public static func groupRate(pids: [Int32], in rates: [Int32: NetworkRate]) -> NetworkRate? {
        let members = pids.compactMap { rates[$0] }
        guard let first = members.first else { return nil }
        return members.dropFirst().reduce(first, +)
    }
}
