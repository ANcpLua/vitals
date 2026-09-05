public struct ProcessCPUSmoother: Sendable {
    private struct Identity: Hashable, Sendable {
        let pid: Int32
        let ppid: Int32
        let name: String
    }

    private let response: Double
    private var values: [Identity: Double] = [:]

    public init(response: Double = 0.3) {
        self.response = response
    }

    public mutating func smooth(_ processes: [ProcessView]) -> [ProcessView] {
        var next: [Identity: Double] = [:]
        let smoothed = processes.map { process in
            let identity = Identity(
                pid: process.pid,
                ppid: process.ppid,
                name: process.name
            )
            let cpuPercent = process.cpuPercent.map { current in
                guard let previous = values[identity] else { return current }
                return previous + response * (current - previous)
            }
            if let cpuPercent {
                next[identity] = cpuPercent
            }
            return ProcessView(
                pid: process.pid,
                ppid: process.ppid,
                name: process.name,
                cpuPercent: cpuPercent,
                footprintBytes: process.footprintBytes,
                residentBytes: process.residentBytes
            )
        }
        values = next
        return smoothed
    }
}
