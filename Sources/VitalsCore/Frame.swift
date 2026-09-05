public struct CpuFrame: Sendable {
    public let user: UInt64
    public let system: UInt64
    public let idle: UInt64
    public let nice: UInt64
    public let cores: Int32

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64, cores: Int32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
        self.cores = cores
    }
}

public struct MemoryFrame: Sendable {
    public let pageSize: UInt64
    public let total: UInt64
    public let freePages: UInt64
    public let activePages: UInt64
    public let inactivePages: UInt64
    public let wiredPages: UInt64
    public let compressedPages: UInt64
    public let externalPages: UInt64
    public let purgeablePages: UInt64
    public let internalPages: UInt64
    public let swapins: UInt64
    public let swapouts: UInt64
    public let swapUsed: UInt64
    public let swapTotal: UInt64
    public let pressureLevel: Int32

    public init(
        pageSize: UInt64,
        total: UInt64,
        freePages: UInt64,
        activePages: UInt64,
        inactivePages: UInt64,
        wiredPages: UInt64,
        compressedPages: UInt64,
        externalPages: UInt64,
        purgeablePages: UInt64,
        internalPages: UInt64,
        swapins: UInt64,
        swapouts: UInt64,
        swapUsed: UInt64,
        swapTotal: UInt64,
        pressureLevel: Int32
    ) {
        self.pageSize = pageSize
        self.total = total
        self.freePages = freePages
        self.activePages = activePages
        self.inactivePages = inactivePages
        self.wiredPages = wiredPages
        self.compressedPages = compressedPages
        self.externalPages = externalPages
        self.purgeablePages = purgeablePages
        self.internalPages = internalPages
        self.swapins = swapins
        self.swapouts = swapouts
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.pressureLevel = pressureLevel
    }
}

public struct ProcessFrame: Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let name: String
    public let cpuNanos: UInt64
    public let residentBytes: UInt64
    public let footprintBytes: UInt64?

    public init(
        pid: Int32,
        ppid: Int32,
        name: String,
        cpuNanos: UInt64,
        residentBytes: UInt64,
        footprintBytes: UInt64?
    ) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.cpuNanos = cpuNanos
        self.residentBytes = residentBytes
        self.footprintBytes = footprintBytes
    }
}

public struct DiskFrame: Sendable {
    public let freeBytes: UInt64
    public let availableBytes: UInt64
    public let totalBytes: UInt64

    public init(freeBytes: UInt64, availableBytes: UInt64, totalBytes: UInt64) {
        self.freeBytes = freeBytes
        self.availableBytes = availableBytes
        self.totalBytes = totalBytes
    }
}

public struct Frame: Sendable {
    public let monotonicNanos: UInt64
    public let cpu: CpuFrame
    public let memory: MemoryFrame
    public let disk: DiskFrame
    public let processes: [ProcessFrame]

    public init(monotonicNanos: UInt64, cpu: CpuFrame, memory: MemoryFrame, disk: DiskFrame, processes: [ProcessFrame]) {
        self.monotonicNanos = monotonicNanos
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.processes = processes
    }
}
