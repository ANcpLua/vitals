import Foundation
import VitalsCore

enum Format {
    static func gib(_ bytes: UInt64) -> String {
        String(format: "%6.2f GiB", Double(bytes) / 1_073_741_824.0)
    }

    static func gb(_ bytes: UInt64) -> String {
        String(format: "%6.2f GB", Double(bytes) / 1_000_000_000.0)
    }

    static func clock() -> String {
        var now = time(nil)
        var parts = tm()
        localtime_r(&now, &parts)
        var buffer = [UInt8](repeating: 0, count: 16)
        let written = buffer.withUnsafeMutableBytes { raw in
            strftime(raw.baseAddress!.assumingMemoryBound(to: CChar.self), raw.count, "%H:%M:%S", &parts)
        }
        return String(decoding: buffer.prefix(written), as: UTF8.self)
    }

    /// "just now", "42s", "7m", "3h", "2d" — compact relative age for menu rows.
    static func age(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        return "\(Int(seconds / 86_400))d"
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "    -- " }
        return String(format: "%6.1f%%", value)
    }

    static func footprint(_ bytes: UInt64?) -> String {
        guard let bytes else { return "      -- " }
        return gib(bytes)
    }

    static func pressure(_ value: Pressure) -> String {
        switch value {
        case .green: "GREEN"
        case .yellow: "YELLOW"
        case .red: "RED"
        }
    }

    static func row(_ process: ProcessView) -> String {
        let pid = String(format: "%7d", process.pid)
        let cpu = percent(process.cpuPercent)
        let mem = footprint(process.footprintBytes)
        let name = process.name.count > 30 ? String(process.name.prefix(30)) : process.name
        return "\(pid)  \(cpu)  \(mem)  \(name)"
    }
}
