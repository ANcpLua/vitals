import Foundation

/// Finding the spot for a phone hotspot or a 5G modem: a paced upload runs while
/// the user turns and moves the device, and every quarter second the last second
/// of upload is compared with the best the user has reached so far. The panel
/// colours itself and a tone rises with the quality, so the user can move the
/// device without looking at the screen.
public enum PlacementGrade: String, Equatable, Sendable {
    case good, fair, poor, dropout
}

public struct PlacementVerdict: Equatable, Sendable {
    public let grade: PlacementGrade
    /// Upload of the last second divided by the reference; 0 on a dropout.
    public let quality: Double

    public init(grade: PlacementGrade, quality: Double) {
        self.grade = grade
        self.quality = quality
    }
}

public enum Placement {
    /// Samples per second the panel takes and judges.
    public static let hz = 4
    /// The best value is the best average over this many seconds, so a single
    /// burst after a stall does not raise the bar.
    public static let bestWindowSeconds = 3
    public static let limits: [Double] = [5, 10, 20, 50]
    public static let defaultLimit: Double = 10
    /// The upload stops on its own this long after the last Start.
    public static let autoStopSeconds: TimeInterval = 300

    /// What a spot is measured against: the best the user has reached, never
    /// more than the upload limit. Before any best exists, the limit itself.
    public static func reference(best: Double, limitMbit: Double) -> Double {
        best > 0 ? min(best, limitMbit) : limitMbit
    }

    /// Raises the best value when the last `bestWindowSeconds` were all uploading.
    /// `recent` holds the per-sample upload in Mbit/s, nil while stopped.
    public static func best(previous: Double, recent: [Double?]) -> Double {
        let count = hz * bestWindowSeconds
        guard recent.count >= count else { return previous }
        let window = recent.suffix(count)
        guard window.allSatisfy({ $0 != nil }) else { return previous }
        let average = window.reduce(0) { $0 + ($1 ?? 0) } / Double(count)
        return max(previous, average)
    }

    /// Verdict for the last second. A ping lost within that second is a
    /// dropout whatever the upload says.
    public static func decide(uploadMbit: Double, lostPing: Bool, reference: Double) -> PlacementVerdict {
        if lostPing { return PlacementVerdict(grade: .dropout, quality: 0) }
        let quality = reference > 0 ? max(0, uploadMbit / reference) : 0
        if quality >= 0.85 { return PlacementVerdict(grade: .good, quality: quality) }
        if quality >= 0.6 { return PlacementVerdict(grade: .fair, quality: quality) }
        return PlacementVerdict(grade: .poor, quality: quality)
    }

    /// Tone pitch: 220 Hz for nothing, 880 Hz at the reference, a little more above it.
    public static func toneHz(quality: Double) -> Double {
        220 + 660 * min(1.2, max(0, quality))
    }
}

/// Upload rate over a sliding window from a running total of acknowledged bytes.
public struct UploadWindow: Sendable {
    public let seconds: TimeInterval
    private var points: [(time: TimeInterval, bytes: Int64)] = []

    public init(seconds: TimeInterval = 1) {
        self.seconds = seconds
    }

    /// Adds a reading and returns Mbit/s over the window. A total that went
    /// backwards (unsent bytes dropped with a closed connection) restarts it.
    public mutating func adding(time: TimeInterval, bytes: Int64) -> Double {
        if let last = points.last, bytes < last.bytes { points.removeAll() }
        points.append((time, bytes))
        while points.count > 1, time - points[0].time > seconds + 0.01 { points.removeFirst() }
        guard let first = points.first, time > first.time else { return 0 }
        return Double(bytes - first.bytes) * 8 / 1_000_000 / (time - first.time)
    }

    public mutating func reset() {
        points.removeAll()
    }
}
