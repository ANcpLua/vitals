import Foundation
import VitalsCore

enum Printer {
    static func out(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    static func err(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    static func dashboard(_ snapshot: Snapshot, alarms: AlarmState, top: Int) {
        out("\u{1b}[2J\u{1b}[Hvitals \(Format.clock())   \(badge(alarms))")
        Printer.snapshot(snapshot, top: top)
    }

    static func badge(_ state: AlarmState) -> String {
        var parts: [String] = []
        if state.diskFiring { parts.append("DISK-LOW") }
        if state.memoryFiring { parts.append("MEM-RED") }
        return parts.isEmpty ? "ok" : "ALARM " + parts.joined(separator: " ")
    }

    static func snapshot(_ snapshot: Snapshot, top: Int) {
        let memory = snapshot.memory
        let capacity = Double(snapshot.cores) * 100.0
        let other = snapshot.cpuPercent.map { max(0, $0 - snapshot.attributedCpuPercent) }
        out("cpu      \(Format.percent(snapshot.cpuPercent)) / \(Format.percent(capacity))   yours \(Format.percent(snapshot.attributedCpuPercent))   system/other \(Format.percent(other))   pressure \(Format.pressure(memory.pressure))")
        out("memory   used \(Format.gib(memory.used))   avail \(Format.gib(memory.available))   free \(Format.gib(memory.free))")
        out("         wired \(Format.gib(memory.wired))  comp \(Format.gib(memory.compressed))  app \(Format.gib(memory.app))  cache \(Format.gib(memory.cachedFiles))")
        out("         swap \(Format.gib(memory.swapUsed)) of \(Format.gib(memory.swapTotal))   swapouts/interval \(memory.swapRate)")
        out("disk     available \(Format.gb(snapshot.disk.available))   free now \(Format.gb(snapshot.disk.free))   total \(Format.gb(snapshot.disk.total))")
        out("")
        out("    pid     cpu       mem  process")
        for process in snapshot.processes.prefix(top) {
            out(Format.row(process))
        }
    }

    static func prediction(_ prediction: KillPrediction, in snapshot: Snapshot) {
        let name = snapshot.processes.first { $0.pid == prediction.pid }?.name ?? "pid \(prediction.pid)"
        out("kill \(prediction.pid) (\(name))")
        out("  subtree            \(prediction.subtree.count) readable process(es)")
        let unknown = prediction.reclaimUnknownCount > 0 ? " (\(prediction.reclaimUnknownCount) footprint unknown)" : ""
        out("  reclaim memory     up to \(Format.gib(prediction.reclaimBytes))\(unknown)")
        out("  reclaim cpu        \(Format.percent(prediction.reclaimCpuPercent))")
        out("  available after    \(Format.gib(prediction.availableAfter)) (optimistic)")
        out("  pressure (est)     \(Format.pressure(snapshot.memory.pressure)) -> \(Format.pressure(prediction.pressureAfter))")
    }

    static func json<Value: Encodable>(_ value: Value) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else {
            err("error encode")
            return
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    static func describe(_ error: MetricsError) -> String {
        switch error {
        case let .syscall(name, code): "error syscall \(name) code \(code)"
        case let .unexpected(name, value): "error unexpected \(name) value \(value)"
        case let .missing(name): "error missing \(name)"
        }
    }

    static func failure(_ error: MetricsError) {
        err(describe(error))
    }
}
