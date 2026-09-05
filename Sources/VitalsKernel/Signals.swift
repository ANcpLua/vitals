import Darwin
import VitalsCore

public enum Signals {
    public static func send(_ signal: Int32, to pid: Int32) -> Result<Void, MetricsError> {
        kill(pid, signal) == 0
            ? .success(())
            : .failure(.syscall(name: "kill(\(pid), \(signal))", code: errno))
    }

    public static let stop = SIGSTOP
    public static let resume = SIGCONT
    public static let interrupt = SIGINT
    public static let terminate = SIGTERM
    public static let force = SIGKILL
}
