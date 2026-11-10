/// The kernel names a process after its executable file. A tool installed as
/// `<tool>/versions/<version>` therefore shows up as a bare version number: the
/// native Claude Code installer runs `~/.local/share/claude/versions/2.1.321`.
/// Such a process gets its tool name back.
public enum ProcessName {
    /// Digits separated by dots: `2.1.321`.
    public static func isVersionNumber(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count > 1 && parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }
    }

    public static func display(kernelName: String, executablePath: String) -> String {
        guard isVersionNumber(kernelName) else { return kernelName }
        let parts = executablePath.split(separator: "/")
        guard parts.count >= 3, parts[parts.count - 1] == kernelName, parts[parts.count - 2] == "versions" else {
            return kernelName
        }
        return String(parts[parts.count - 3])
    }
}
