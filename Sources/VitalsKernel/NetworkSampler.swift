import Darwin
import Foundation
import VitalsCore

/// Per-process network counters. There is no public API for these; the only
/// supported source is `/usr/bin/nettop`, so this is the one place in the
/// kernel that spawns a process. It costs a few hundred milliseconds of CPU
/// per call, which is why the menu keeps it off by default.
public enum NetworkSampler {
    public static let executable = "/usr/bin/nettop"

    public static func capture() -> Result<NetworkFrame, MetricsError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-P", "-L", "1", "-J", "bytes_in,bytes_out"]
        process.environment = ["LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return .failure(.missing(name: executable))
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard process.terminationStatus == 0 else {
            return .failure(.unexpected(name: "nettop exit status", value: Int(process.terminationStatus)))
        }
        return .success(NetworkFrame(
            monotonicNanos: started,
            counters: Network.parse(String(decoding: data, as: UTF8.self))
        ))
    }
}
