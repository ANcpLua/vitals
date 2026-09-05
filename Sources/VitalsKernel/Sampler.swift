import Darwin
import Foundation
import os
import VitalsCore

public enum Sampler {
    // pti_total_user/system are Mach timebase ticks (125/3 ns on Apple Silicon), not nanoseconds.
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return (1, 1) }
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    static func machToNanos(_ ticks: UInt64) -> UInt64 {
        ticks &* timebase.numer / timebase.denom
    }

    public static func capture() -> Result<Frame, MetricsError> {
        cpu().flatMap { cpuFrame in
            memory().flatMap { memoryFrame in
                disk("/System/Volumes/Data").flatMap { diskFrame in
                    processes().map { procs in
                        Frame(
                            monotonicNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
                            cpu: cpuFrame,
                            memory: memoryFrame,
                            disk: diskFrame,
                            processes: procs
                        )
                    }
                }
            }
        }
    }

    package static func disk(_ path: String) -> Result<DiskFrame, MetricsError> {
        var stats = statfs()
        guard statfs(path, &stats) == 0 else {
            return .failure(.syscall(name: "statfs(\(path))", code: errno))
        }
        let block = UInt64(stats.f_bsize)
        let freeBytes = UInt64(stats.f_bavail) * block
        let resourceValues = try? URL(fileURLWithPath: path, isDirectory: true)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let availableBytes = resourceValues?
            .volumeAvailableCapacityForImportantUsage
            .flatMap { $0 >= 0 ? UInt64($0) : nil }
            ?? freeBytes
        return .success(DiskFrame(
            freeBytes: freeBytes,
            availableBytes: availableBytes,
            totalBytes: UInt64(stats.f_blocks) * block
        ))
    }

    static func cpu() -> Result<CpuFrame, MetricsError> {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return .failure(.syscall(name: "host_statistics(HOST_CPU_LOAD_INFO)", code: result))
        }

        var cores: Int32 = 0
        var coresSize = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.ncpu", &cores, &coresSize, nil, 0) == 0, cores > 0 else {
            return .failure(.syscall(name: "sysctlbyname(hw.ncpu)", code: errno))
        }

        return .success(CpuFrame(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3),
            cores: cores
        ))
    }

    static func memory() -> Result<MemoryFrame, MetricsError> {
        var pageSize: vm_size_t = 0
        let pageResult = host_page_size(mach_host_self(), &pageSize)
        guard pageResult == KERN_SUCCESS else {
            return .failure(.syscall(name: "host_page_size", code: pageResult))
        }

        var total: UInt64 = 0
        var totalSize = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &total, &totalSize, nil, 0) == 0 else {
            return .failure(.syscall(name: "sysctlbyname(hw.memsize)", code: errno))
        }

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return .failure(.syscall(name: "host_statistics64(HOST_VM_INFO64)", code: result))
        }

        var pressureLevel: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureLevel, &pressureSize, nil, 0) == 0 else {
            return .failure(.syscall(name: "sysctlbyname(kern.memorystatus_vm_pressure_level)", code: errno))
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 else {
            return .failure(.syscall(name: "sysctlbyname(vm.swapusage)", code: errno))
        }

        return .success(MemoryFrame(
            pageSize: UInt64(pageSize),
            total: total,
            freePages: UInt64(stats.free_count),
            activePages: UInt64(stats.active_count),
            inactivePages: UInt64(stats.inactive_count),
            wiredPages: UInt64(stats.wire_count),
            compressedPages: UInt64(stats.compressor_page_count),
            externalPages: UInt64(stats.external_page_count),
            purgeablePages: UInt64(stats.purgeable_count),
            internalPages: UInt64(stats.internal_page_count),
            swapins: UInt64(stats.swapins),
            swapouts: UInt64(stats.swapouts),
            swapUsed: swap.xsu_used,
            swapTotal: swap.xsu_total,
            pressureLevel: pressureLevel
        ))
    }

    static func processes() -> Result<[ProcessFrame], MetricsError> {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else {
            return .failure(.syscall(name: "proc_listpids(size)", code: errno))
        }
        let capacity = Int(needed) / MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, needed)
        guard written > 0 else {
            return .failure(.syscall(name: "proc_listpids(fill)", code: errno))
        }
        let live = pids.prefix(Int(written) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }
        let frames = live.compactMap(sample)
        let livePids = Set(live)
        names.withLock { cache in
            for pid in cache.keys where !livePids.contains(pid) {
                cache.removeValue(forKey: pid)
            }
        }
        return .success(frames)
    }

    private struct Identity {
        let startSeconds: UInt64
        let name: String
    }

    // proc_name is a syscall plus a fresh String per call, and a process's name is
    // immutable for its lifetime — memoize by (pid, start time); the start time makes
    // pid reuse safe. Evicted in processes() once a pid disappears, so the cache is
    // bounded by the live process count.
    private static let names = OSAllocatedUnfairLock(initialState: [pid_t: Identity]())

    // Test hook for the selftest target: proc_name fetches (cache misses) so far.
    package static let nameFetches = OSAllocatedUnfairLock(initialState: 0)

    static func sample(_ pid: pid_t) -> ProcessFrame? {
        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize else {
            return nil
        }

        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let hasBsd = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize
        let ppid: Int32 = hasBsd ? Int32(bitPattern: bsd.pbi_ppid) : -1
        let started: UInt64 = hasBsd ? bsd.pbi_start_tvsec : 0

        return ProcessFrame(
            pid: pid,
            ppid: ppid,
            name: memoizedName(pid, startedSeconds: started),
            cpuNanos: machToNanos(task.pti_total_user &+ task.pti_total_system),
            residentBytes: task.pti_resident_size,
            footprintBytes: footprint(pid)
        )
    }

    static func memoizedName(_ pid: pid_t, startedSeconds: UInt64) -> String {
        if startedSeconds != 0,
           let hit = names.withLock({ $0[pid] }),
           hit.startSeconds == startedSeconds {
            return hit.name
        }
        nameFetches.withLock { $0 += 1 }
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = buffer.withUnsafeMutableBytes { raw in
            proc_name(pid, raw.baseAddress, UInt32(raw.count))
        }
        let decoded = String(decoding: buffer.prefix(Int(max(length, 0))), as: UTF8.self)
        let name = decoded.isEmpty ? "pid \(pid)" : decoded
        if startedSeconds != 0 {
            names.withLock { $0[pid] = Identity(startSeconds: startedSeconds, name: name) }
        }
        return name
    }

    static func footprint(_ pid: pid_t) -> UInt64? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        return usage.ri_phys_footprint
    }
}
