public enum Derive {
    public static func snapshot(previous: Frame, current: Frame) -> Snapshot {
        let wallDelta = current.monotonicNanos >= previous.monotonicNanos
            ? current.monotonicNanos - previous.monotonicNanos
            : 0
        let prevCpuByPid = Dictionary(
            previous.processes.map { ($0.pid, $0.cpuNanos) },
            uniquingKeysWith: { first, _ in first }
        )
        let views = current.processes.map { process -> ProcessView in
            ProcessView(
                pid: process.pid,
                ppid: process.ppid,
                name: process.name,
                cpuPercent: cpuPercent(pid: process.pid, current: process.cpuNanos, previous: prevCpuByPid, wallDelta: wallDelta),
                footprintBytes: process.footprintBytes,
                residentBytes: process.residentBytes
            )
        }
        let sorted = views.sorted(by: ranked)
        let attributed = views.reduce(0.0) { $0 + ($1.cpuPercent ?? 0) }
        return Snapshot(
            cpuPercent: overallCpuPercent(previous: previous.cpu, current: current.cpu),
            attributedCpuPercent: attributed,
            cores: current.cpu.cores,
            memory: memoryView(previous: previous.memory, current: current.memory),
            disk: DiskView(
                free: current.disk.freeBytes,
                available: current.disk.availableBytes,
                total: current.disk.totalBytes
            ),
            processes: sorted
        )
    }

    public static func groups(_ processes: [ProcessView]) -> [ProcessGroup] {
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [Int32: [Int32]] = [:]
        var roots: [ProcessView] = []
        for process in processes {
            if process.ppid > 1, process.ppid != process.pid, byPid[process.ppid] != nil {
                children[process.ppid, default: []].append(process.pid)
            } else {
                roots.append(process)
            }
        }
        return roots.map { root in
            var members: [ProcessView] = []
            var stack: [Int32] = [root.pid]
            while let pid = stack.popLast() {
                guard let view = byPid[pid] else { continue }
                members.append(view)
                stack.append(contentsOf: children[pid] ?? [])
            }
            members.sort(by: ranked)
            let cpuValues = members.compactMap(\.cpuPercent)
            let footprints = members.compactMap(\.footprintBytes)
            return ProcessGroup(
                root: root,
                members: members,
                cpuPercent: cpuValues.isEmpty ? nil : cpuValues.reduce(0, +),
                footprintBytes: footprints.isEmpty ? nil : footprints.reduce(0, +)
            )
        }
        .sorted { lhs, rhs in
            let left = lhs.cpuPercent ?? -1
            let right = rhs.cpuPercent ?? -1
            guard left == right else { return left > right }
            return (lhs.footprintBytes ?? 0) > (rhs.footprintBytes ?? 0)
        }
    }

    static func ranked(_ lhs: ProcessView, _ rhs: ProcessView) -> Bool {
        let left = lhs.cpuPercent ?? -1
        let right = rhs.cpuPercent ?? -1
        guard left == right else { return left > right }
        return (lhs.footprintBytes ?? 0) > (rhs.footprintBytes ?? 0)
    }

    public static func killPrediction(pid: Int32, in snapshot: Snapshot) -> KillPrediction? {
        let byPid = Dictionary(uniqueKeysWithValues: snapshot.processes.map { ($0.pid, $0) })
        guard byPid[pid] != nil else { return nil }
        var children: [Int32: [Int32]] = [:]
        for process in snapshot.processes {
            children[process.ppid, default: []].append(process.pid)
        }
        var subtree: [Int32] = []
        var stack: [Int32] = [pid]
        while let current = stack.popLast() {
            subtree.append(current)
            if let kids = children[current] {
                stack.append(contentsOf: kids)
            }
        }
        let members = subtree.compactMap { byPid[$0] }
        let known = members.compactMap { $0.footprintBytes }
        let reclaim = known.reduce(UInt64(0), +)
        let unknown = members.count - known.count
        let cpu = members.reduce(0.0) { $0 + ($1.cpuPercent ?? 0) }
        let total = snapshot.memory.total
        let availableAfter = min(total, snapshot.memory.available + reclaim)
        let freeAfter = min(total, snapshot.memory.free + reclaim)
        return KillPrediction(
            pid: pid,
            subtree: subtree,
            reclaimBytes: reclaim,
            reclaimUnknownCount: unknown,
            reclaimCpuPercent: cpu,
            availableAfter: availableAfter,
            pressureAfter: estimatePressure(total: total, free: freeAfter, cached: snapshot.memory.cachedFiles)
        )
    }

    static func cpuPercent(pid: Int32, current: UInt64, previous: [Int32: UInt64], wallDelta: UInt64) -> Double? {
        guard wallDelta > 0, let prior = previous[pid], current >= prior else { return nil }
        return Double(current - prior) / Double(wallDelta) * 100.0
    }

    static func overallCpuPercent(previous: CpuFrame, current: CpuFrame) -> Double? {
        let busyPrev = previous.user &+ previous.system &+ previous.nice
        let busyCur = current.user &+ current.system &+ current.nice
        guard busyCur >= busyPrev, current.idle >= previous.idle else { return nil }
        let busy = busyCur - busyPrev
        let idle = current.idle - previous.idle
        let total = busy + idle
        guard total > 0 else { return nil }
        return Double(busy) / Double(total) * Double(current.cores) * 100.0
    }

    static func memoryView(previous: MemoryFrame, current: MemoryFrame) -> MemoryView {
        let page = current.pageSize
        let wired = current.wiredPages * page
        let compressed = current.compressedPages * page
        let cached = (current.externalPages + current.purgeablePages) * page
        let appPages = current.internalPages >= current.purgeablePages
            ? current.internalPages - current.purgeablePages
            : 0
        let app = appPages * page
        let free = current.freePages * page
        let available = free + cached
        let used = current.total >= available ? current.total - available : 0
        let swapRate = current.swapouts >= previous.swapouts
            ? Int64(current.swapouts - previous.swapouts)
            : 0
        return MemoryView(
            total: current.total,
            wired: wired,
            compressed: compressed,
            app: app,
            cachedFiles: cached,
            free: free,
            available: available,
            used: used,
            swapRate: swapRate,
            swapUsed: current.swapUsed,
            swapTotal: current.swapTotal,
            pressure: mapPressure(current.pressureLevel)
        )
    }

    static func mapPressure(_ level: Int32) -> Pressure {
        if level >= 4 { return .red }
        if level >= 2 { return .yellow }
        return .green
    }

    static func estimatePressure(total: UInt64, free: UInt64, cached: UInt64) -> Pressure {
        guard total > 0 else { return .red }
        let headroom = Double(free + cached) / Double(total)
        if headroom < 0.05 { return .red }
        if headroom < 0.15 { return .yellow }
        return .green
    }
}
