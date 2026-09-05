import Foundation

public enum MCPProbeError: Error, Equatable {
    case notProbeable
    case launchFailed(String)
    case timeout
    case badResponse(String)
    case http(Int)
}

/// Asks one server for its tool list with the minimal MCP handshake:
/// `initialize`, `notifications/initialized`, `tools/list`. Runs only on
/// demand (menu action or `vitals mcp refresh`), never on the 2 s tick: a
/// stdio server is a real process launch, often `npx`.
public enum MCPProbe {
    public static let protocolVersion = "2025-06-18"

    public static func tools(of server: MCPServer, timeout: TimeInterval = 25) -> Result<[MCPTool], MCPProbeError> {
        switch server.transport {
        case let .stdio(command, arguments, environment):
            return stdio(command: command, arguments: arguments, environment: environment,
                         workingDirectory: server.workingDirectory, timeout: timeout)
        case let .http(url, headers):
            return http(url: url, headers: headers, timeout: timeout)
        case .sse, .other:
            return .failure(.notProbeable)
        }
    }

    // MARK: JSON-RPC framing

    static func request(id: Int, method: String, params: [String: Any] = [:]) -> Data {
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        return (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
    }

    static func notification(_ method: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method])) ?? Data()
    }

    static var initializeParams: [String: Any] {
        [
            "protocolVersion": protocolVersion,
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "vitals", "version": "0.7.0"]
        ]
    }

    /// Parses a `tools/list` result out of one JSON-RPC message.
    public static func parseToolsResult(_ object: Any) -> [MCPTool]? {
        guard let message = object as? [String: Any],
              let result = message["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]]
        else { return nil }
        return tools.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            return MCPTool(name: name, description: firstLine(tool["description"] as? String ?? ""))
        }
    }

    /// Finds the response with `id` in newline-delimited JSON (stdio) or in
    /// SSE `data:` lines (HTTP), whichever the text happens to be.
    public static func findResponse(id: Int, in text: String) -> Any? {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = Substring(rawLine.trimmingCharacters(in: .whitespacesAndNewlines))
            if line.hasPrefix("data:") { line = line.dropFirst(5).drop(while: { $0 == " " }) }
            guard line.first == "{", let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["id"] as? Int) == id || (object["id"] as? String) == String(id)
            else { continue }
            return object
        }
        return nil
    }

    static func firstLine(_ text: String) -> String {
        text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
    }

    // MARK: stdio

    static func stdio(
        command: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String?,
        timeout: TimeInterval
    ) -> Result<[MCPTool], MCPProbeError> {
        var env = LoginShell.environment
        for (key, value) in environment { env[key] = expand(value, env) }
        let process = Process()
        let resolved = resolve(command, path: env["PATH"] ?? "")
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = arguments.map { expand($0, env) }
        process.environment = env
        if let workingDirectory, FileManager.default.fileExists(atPath: workingDirectory) {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failure(.launchFailed("\(resolved): \(error.localizedDescription)"))
        }

        let writer = input.fileHandleForWriting
        for frame in [request(id: 1, method: "initialize", params: initializeParams),
                      notification("notifications/initialized"),
                      request(id: 2, method: "tools/list")] {
            writer.write(frame)
            writer.write(Data("\n".utf8))
        }

        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        let reader = output.fileHandleForReading
        var found: Any?
        while Date() < deadline {
            let chunk = reader.availableData
            if chunk.isEmpty {
                if !process.isRunning { break }
                usleep(50_000)
                continue
            }
            buffer.append(chunk)
            if let response = findResponse(id: 2, in: String(decoding: buffer, as: UTF8.self)) {
                found = response
                break
            }
        }
        try? writer.close()
        if process.isRunning { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        guard let found else {
            return .failure(process.isRunning || Date() >= deadline ? .timeout : .badResponse("server exited before answering tools/list"))
        }
        guard let tools = parseToolsResult(found) else {
            return .failure(.badResponse("tools/list result has no tools array"))
        }
        return .success(tools)
    }

    /// `${VAR}` and `${VAR:-default}` the way Claude Code expands them.
    static func expand(_ value: String, _ env: [String: String]) -> String {
        guard value.contains("${") else { return value }
        var result = ""
        var rest = Substring(value)
        while let start = rest.range(of: "${") {
            result += rest[..<start.lowerBound]
            guard let end = rest[start.upperBound...].firstIndex(of: "}") else {
                result += rest[start.lowerBound...]
                return result
            }
            let inner = rest[start.upperBound..<end]
            let pieces = inner.split(separator: ":", maxSplits: 1).map(String.init)
            let key = pieces.first ?? ""
            let fallback = pieces.count > 1 ? String(pieces[1].dropFirst(pieces[1].hasPrefix("-") ? 1 : 0)) : ""
            result += env[key] ?? fallback
            rest = rest[rest.index(after: end)...]
        }
        return result + rest
    }

    static func resolve(_ command: String, path: String) -> String {
        if command.contains("/") { return (command as NSString).expandingTildeInPath }
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return command
    }

    // MARK: HTTP (streamable)

    static func http(url: String, headers: [String: String], timeout: TimeInterval) -> Result<[MCPTool], MCPProbeError> {
        guard let endpoint = URL(string: url) else { return .failure(.launchFailed(url)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        func post(_ body: Data, sessionId: String?) -> Result<(String, String?), MCPProbeError> {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
            if let sessionId { request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id") }
            for (key, value) in headers { request.setValue(expand(value, LoginShell.environment), forHTTPHeaderField: key) }
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var outcome: Result<(String, String?), MCPProbeError> = .failure(.timeout)
            session.dataTask(with: request) { data, response, error in
                defer { semaphore.signal() }
                if let error { outcome = .failure(.launchFailed(error.localizedDescription)); return }
                guard let http = response as? HTTPURLResponse else { outcome = .failure(.badResponse("no HTTP response")); return }
                guard (200..<300).contains(http.statusCode) else { outcome = .failure(.http(http.statusCode)); return }
                outcome = .success((
                    String(decoding: data ?? Data(), as: UTF8.self),
                    http.value(forHTTPHeaderField: "Mcp-Session-Id")
                ))
            }.resume()
            guard semaphore.wait(timeout: .now() + timeout) == .success else { return .failure(.timeout) }
            return outcome
        }

        return post(request(id: 1, method: "initialize", params: initializeParams), sessionId: nil).flatMap { _, sessionId in
            _ = post(notification("notifications/initialized"), sessionId: sessionId)
            return post(request(id: 2, method: "tools/list"), sessionId: sessionId).flatMap { text, _ in
                guard let response = findResponse(id: 2, in: text) else {
                    return .failure(.badResponse("no tools/list response in body"))
                }
                guard let tools = parseToolsResult(response) else {
                    return .failure(.badResponse("tools/list result has no tools array"))
                }
                return .success(tools)
            }
        }
    }
}

/// The interactive shell's environment, resolved once. A LaunchAgent gets a
/// bare PATH; the user's servers (`npx` under nvm, `uvx`, `docker`) live on
/// the login PATH, the same one Claude Code inherits from the terminal.
enum LoginShell {
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let process = Process()
        process.executableURL = URL(fileURLWithPath: env["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-lc", "command env"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return env }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            env[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return env
    }()
}
