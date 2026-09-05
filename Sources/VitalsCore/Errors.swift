public enum MetricsError: Error, Sendable, Equatable {
    case syscall(name: String, code: Int32)
    case unexpected(name: String, value: Int)
    case missing(name: String)
}
