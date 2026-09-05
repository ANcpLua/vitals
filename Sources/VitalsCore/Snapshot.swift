public enum Pressure: String, Sendable, Equatable, Codable {
    case green
    case yellow
    case red
}

public struct ProcessView: Sendable, Equatable, Codable {
    public let pid: Int32
    public let ppid: Int32
    public let name: String
    public let cpuPercent: Double?
    public let footprintBytes: UInt64?
    public let residentBytes: UInt64

    public init(
        pid: Int32,
        ppid: Int32,
        name: String,
        cpuPercent: Double?,
        footprintBytes: UInt64?,
        residentBytes: UInt64
    ) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.cpuPercent = cpuPercent
        self.footprintBytes = footprintBytes
        self.residentBytes = residentBytes
    }
}

public struct MemoryView: Sendable, Equatable, Codable {
    public let total: UInt64
    public let wired: UInt64
    public let compressed: UInt64
    public let app: UInt64
    public let cachedFiles: UInt64
    public let free: UInt64
    public let available: UInt64
    public let used: UInt64
    public let swapRate: Int64
    public let swapUsed: UInt64
    public let swapTotal: UInt64
    public let pressure: Pressure

    public init(
        total: UInt64,
        wired: UInt64,
        compressed: UInt64,
        app: UInt64,
        cachedFiles: UInt64,
        free: UInt64,
        available: UInt64,
        used: UInt64,
        swapRate: Int64,
        swapUsed: UInt64,
        swapTotal: UInt64,
        pressure: Pressure
    ) {
        self.total = total
        self.wired = wired
        self.compressed = compressed
        self.app = app
        self.cachedFiles = cachedFiles
        self.free = free
        self.available = available
        self.used = used
        self.swapRate = swapRate
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.pressure = pressure
    }
}

public struct DiskView: Sendable, Equatable, Codable {
    public let free: UInt64
    public let available: UInt64
    public let total: UInt64

    public init(free: UInt64, available: UInt64, total: UInt64) {
        self.free = free
        self.available = available
        self.total = total
    }
}

public struct Snapshot: Sendable, Equatable, Codable {
    public let cpuPercent: Double?
    public let attributedCpuPercent: Double
    public let cores: Int32
    public let memory: MemoryView
    public let disk: DiskView
    public let processes: [ProcessView]

    public init(cpuPercent: Double?, attributedCpuPercent: Double, cores: Int32, memory: MemoryView, disk: DiskView, processes: [ProcessView]) {
        self.cpuPercent = cpuPercent
        self.attributedCpuPercent = attributedCpuPercent
        self.cores = cores
        self.memory = memory
        self.disk = disk
        self.processes = processes
    }
}

public struct ProcessGroup: Sendable, Equatable, Codable {
    public let root: ProcessView
    public let members: [ProcessView]
    public let cpuPercent: Double?
    public let footprintBytes: UInt64?

    public init(root: ProcessView, members: [ProcessView], cpuPercent: Double?, footprintBytes: UInt64?) {
        self.root = root
        self.members = members
        self.cpuPercent = cpuPercent
        self.footprintBytes = footprintBytes
    }
}

public struct KillPrediction: Sendable, Equatable, Codable {
    public let pid: Int32
    public let subtree: [Int32]
    public let reclaimBytes: UInt64
    public let reclaimUnknownCount: Int
    public let reclaimCpuPercent: Double
    public let availableAfter: UInt64
    public let pressureAfter: Pressure

    public init(
        pid: Int32,
        subtree: [Int32],
        reclaimBytes: UInt64,
        reclaimUnknownCount: Int,
        reclaimCpuPercent: Double,
        availableAfter: UInt64,
        pressureAfter: Pressure
    ) {
        self.pid = pid
        self.subtree = subtree
        self.reclaimBytes = reclaimBytes
        self.reclaimUnknownCount = reclaimUnknownCount
        self.reclaimCpuPercent = reclaimCpuPercent
        self.availableAfter = availableAfter
        self.pressureAfter = pressureAfter
    }
}
