import AppKit
import VitalsClaude
import VitalsCore
import VitalsKernel
import VitalsMCP

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let claudeTelemetry = ClaudeTelemetryClient()
    private let claudeHome = ClaudeHome()
    private var alarmState = AlarmState()
    private var claudeAlertState = ClaudeAlertState()
    private var processCPUSmoother = ProcessCPUSmoother()
    /// Raw per-process CPU for the last 60 s (30 samples at the 2 s tick).
    /// Ranks the process list by window peak and lets exited rows linger.
    private var history = ProcessCPUHistory()
    private var previous: Frame?
    /// Opt-in: nettop costs real CPU per sample, so it is off unless the user
    /// switches it on in the menu. Persisted in UserDefaults.
    private var networkEnabled = UserDefaults.standard.bool(forKey: MenuBarController.networkDefaultsKey)
    private var previousNetwork: NetworkFrame?
    private var networkRates: [Int32: NetworkRate] = [:]
    private static let networkDefaultsKey = "networkStatsEnabled"
    /// Stay-awake policy. Persisted, re-applied at launch and on every tick,
    /// so a Vitals restart re-creates the assertions before the display
    /// notices anything.
    private var awakeMode = AwakeMode(rawValue: UserDefaults.standard.string(forKey: MenuBarController.awakeDefaultsKey) ?? "") ?? .off
    private let awakeAssertions = AwakeAssertions()
    private var powerContext = PowerSampler.context()
    private var awakeDecision = AwakeDecision(holdSystem: false, holdDisplay: false, overrideLidSleep: false, reason: "off", warning: false)
    private var awakeItem: NSMenuItem?
    private static let awakeDefaultsKey = "awakeMode"
    private var lastSnapshot: Snapshot?
    private var claudeSnapshot: ClaudeTelemetrySnapshot?
    private var claudeSessions = ClaudeSessionsSnapshot.empty
    /// MCP servers for the projects of the live sessions plus home. Cheap
    /// file reads on every menu open; tool lists come from the on-disk cache
    /// and are refreshed only through an explicit probe action.
    private var mcpSnapshot = MCPSnapshot.empty
    private var mcpCache = MCPToolCache.load()
    private var mcpProbing: Set<String> = []
    private var mcpHeaderView: MCPHeaderView?
    private var mcpRows: [(name: String, view: MCPRowView)] = []
    private var menuIsOpen = false
    private var claudeRefreshInFlight = false
    /// Set after the Keychain refused a read; background polling stays off
    /// until the user hits Refresh so the system dialog never loops.
    private var claudeUsageSuspended = false
    private var dashboardView: VitalsDashboardView?
    private var claudeView: ClaudeSectionView?
    private var refreshHintView: HintActionView?
    private var groupRows: [(pid: Int32, name: String, identities: [ProcessCPUHistory.Identity], view: ProcessRowView)] = []
    private var memberRows: [(pid: Int32, name: String, item: NSMenuItem)] = []
    private let thresholds = Thresholds(
        diskAvailableBytes: 10_000_000_000,
        diskRecoverAvailableBytes: 12_000_000_000
    )

    func start() {
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular)
        statusItem.button?.title = " Vitals"
        statusItem.button?.image = NSImage(
            systemSymbolName: "waveform.path.ecg",
            accessibilityDescription: "Vitals"
        )
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.imagePosition = .imageLeading
        menu.appearance = NSAppearance(named: .darkAqua)
        menu.minimumWidth = menuWidth
        statusItem.menu = menu
        menu.delegate = self
        menu.addItem(quitItem())
        applyAwake(powerContext)
        refresh()
        refreshClaude()
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.refresh()
            }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                guard let self else { return }
                self.refreshClaude()
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        claudeSessions = ClaudeSessionStore.load(home: claudeHome)
        reloadMCP()
        if let snapshot = lastSnapshot {
            render(snapshot)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        Task { @MainActor [weak self] in
            guard let self, !self.menuIsOpen else { return }
            self.menu.removeAllItems()
            self.dashboardView = nil
            self.claudeView = nil
            self.refreshHintView = nil
            self.groupRows = []
            self.memberRows = []
            self.mcpHeaderView = nil
            self.mcpRows = []
            self.menu.addItem(self.quitItem())
        }
    }

    // MARK: MCP

    private var mcpProjects: [String] {
        var projects = [FileManager.default.homeDirectoryForCurrentUser.path]
        for session in claudeSessions.sessions where !projects.contains(session.cwd) {
            projects.append(session.cwd)
        }
        return projects
    }

    private func reloadMCP() {
        mcpSnapshot = MCPConfigStore.load(home: claudeHome, projects: mcpProjects)
    }

    private func addMCPItems() {
        guard !mcpSnapshot.servers.isEmpty else { return }
        let header = MCPHeaderView(width: menuWidth) { [weak self] in
            guard let self else { return }
            Clipboard.copy(MCPText.lines(self.mcpSnapshot.servers, tools: self.mcpCache.tools))
        }
        mcpHeaderView = header
        menu.addItem(viewItem(header))
        for server in mcpSnapshot.servers.prefix(8) {
            let row = MCPRowView(width: menuWidth)
            mcpRows.append((name: server.name, view: row))
            let item = viewItem(row)
            item.submenu = mcpSubmenu(for: server)
            menu.addItem(item)
        }
        if mcpSnapshot.servers.count > 8 {
            menu.addItem(label("… \(mcpSnapshot.servers.count - 8) more, all included in Copy all"))
        }
        updateMCPRows()
        menu.addItem(.separator())
    }

    private func updateMCPRows() {
        mcpHeaderView?.update(
            servers: mcpSnapshot.servers.count,
            tools: mcpCache.toolCount,
            probing: !mcpProbing.isEmpty
        )
        let byName = Dictionary(mcpSnapshot.servers.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for row in mcpRows {
            guard let server = byName[row.name] else { continue }
            row.view.update(server, record: mcpCache.records[server.name], probing: mcpProbing.contains(server.name)) { [weak self] in
                guard let self else { return }
                Clipboard.copy(MCPText.line(server, tools: self.mcpCache.tools[server.name]))
            }
        }
    }

    private func mcpSubmenu(for server: MCPServer) -> NSMenu {
        let submenu = NSMenu()
        submenu.appearance = NSAppearance(named: .darkAqua)
        let tools = mcpCache.tools[server.name]
        submenu.addItem(mcpAction("Copy line with callable tools", color: Palette.primary) { [weak self] in
            guard let self else { return }
            Clipboard.copy(MCPText.line(server, tools: self.mcpCache.tools[server.name]))
        })
        if let tools, !tools.isEmpty {
            submenu.addItem(mcpAction("Copy ToolSearch query (\(tools.count) tools)", color: Palette.primary) {
                Clipboard.copy(MCPText.toolSearchQuery(server: server, tools: tools))
            })
        }
        submenu.addItem(mcpAction(
            server.transport.isProbeable ? "Probe tools now (launches the server)" : "Cannot probe \(server.transport.summary)",
            color: server.transport.isProbeable ? Palette.blue : Palette.secondary
        ) { [weak self] in
            self?.probe(server)
        })
        submenu.addItem(.separator())
        for project in mcpSnapshot.projects {
            guard let status = server.status[project] else { continue }
            let enabled = status == .enabled
            let path = abbreviated(project)
            let title: String
            let color: NSColor
            switch status {
            case .enabled: title = "✓ \(path)"; color = Palette.mint
            case .disabled: title = "○ \(path) · disabled"; color = Palette.secondary
            case .pendingApproval: title = "? \(path) · approve"; color = Palette.blue
            case .pluginOff: title = "○ \(path) · plugin off"; color = Palette.secondary
            }
            let item = mcpAction(title, color: color) { [weak self] in
                guard let self, status != .pluginOff else { return }
                do {
                    try MCPToggle.write(enabled ? .disable : .enable, server: server, project: project, home: self.claudeHome)
                } catch {
                    Printer.err("mcp toggle: \(error)")
                }
                self.reloadMCP()
                if let lastSnapshot = self.lastSnapshot, self.menuIsOpen { self.render(lastSnapshot) }
            }
            item.toolTip = status == .pluginOff
                ? "Enable the plugin in settings.json first"
                : "Click to \(enabled ? "disable" : "enable") for new sessions in \(project). Running sessions are not touched."
            submenu.addItem(item)
        }
        if let tools, !tools.isEmpty {
            submenu.addItem(.separator())
            for tool in tools.prefix(40) {
                let item = mcpAction(tool.name, color: Palette.primary) {
                    Clipboard.copy(MCPText.callableName(server: server.name, tool: tool.name))
                }
                item.toolTip = tool.description.isEmpty
                    ? "Click to copy \(MCPText.callableName(server: server.name, tool: tool.name))"
                    : "\(tool.description)\nClick to copy \(MCPText.callableName(server: server.name, tool: tool.name))"
                submenu.addItem(item)
            }
            if tools.count > 40 {
                submenu.addItem(label("… \(tools.count - 40) more, all in the copied line"))
            }
        } else if let record = mcpCache.records[server.name], let error = record.error {
            submenu.addItem(.separator())
            submenu.addItem(label("last probe failed: \(error)", color: Palette.coral))
        }
        return submenu
    }

    private func mcpAction(_ title: String, color: NSColor, _ handler: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runMCPAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = MCPActionBox(handler)
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: color]
        )
        return item
    }

    @objc private func runMCPAction(_ sender: NSMenuItem) {
        (sender.representedObject as? MCPActionBox)?.handler()
    }

    private func probe(_ server: MCPServer) {
        guard !mcpProbing.contains(server.name) else { return }
        mcpProbing.insert(server.name)
        updateMCPRows()
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { MCPProbe.tools(of: server) }.value
            guard let self else { return }
            let record: MCPProbeRecord
            switch result {
            case let .success(tools): record = MCPProbeRecord(tools: tools, error: nil, probedAt: Date())
            case let .failure(error): record = MCPProbeRecord(tools: [], error: Self.describe(error), probedAt: Date())
            }
            self.mcpCache.records[server.name] = record
            try? self.mcpCache.save()
            self.mcpProbing.remove(server.name)
            if let lastSnapshot = self.lastSnapshot, self.menuIsOpen { self.render(lastSnapshot) } else { self.updateMCPRows() }
        }
    }

    private static func describe(_ error: MCPProbeError) -> String {
        switch error {
        case .notProbeable: "transport cannot be probed"
        case let .launchFailed(detail): "launch failed: \(detail)"
        case .timeout: "no tools/list answer within the timeout"
        case let .badResponse(detail): detail
        case let .http(code): "HTTP \(code)"
        }
    }

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private var menuWidth: CGFloat { networkEnabled ? 352 + ProcessRowView.networkWidth + 8 : 352 }

    private func refresh() {
        let last = previous
        let wantsNetwork = networkEnabled
        let sample = Task.detached(priority: .utility) {
            Self.sample(previous: last, network: wantsNetwork)
        }
        Task { [weak self] in
            self?.apply(await sample.value)
        }
    }

    private struct Sample: Sendable {
        let frame: Frame
        let snapshot: Snapshot
        /// `nil` when network sampling is off or nettop failed; a failed
        /// nettop run must never take the CPU/memory tick down with it.
        let network: NetworkFrame?
        let power: PowerContext
    }

    nonisolated private static func sample(previous: Frame?, network: Bool) -> Result<Sample, MetricsError> {
        let metrics: Result<(Frame, Snapshot), MetricsError>
        if let previous {
            metrics = Sampler.capture().map { ($0, Derive.snapshot(previous: previous, current: $0)) }
        } else {
            metrics = Sampler.capture().flatMap { first in
                usleep(300_000)
                return Sampler.capture().map { ($0, Derive.snapshot(previous: first, current: $0)) }
            }
        }
        let networkFrame = network ? try? NetworkSampler.capture().get() : nil
        let power = PowerSampler.context()
        return metrics.map { Sample(frame: $0.0, snapshot: $0.1, network: networkFrame, power: power) }
    }

    private func apply(_ result: Result<Sample, MetricsError>) {
        switch result {
        case let .success(sample):
            let frame = sample.frame
            let snapshot = sample.snapshot
            previous = frame
            if let current = sample.network {
                if let before = previousNetwork {
                    networkRates = Network.rates(previous: before, current: current)
                }
                previousNetwork = current
            }
            applyAwake(sample.power)
            history.record(snapshot.processes)
            let processes = processCPUSmoother.smooth(snapshot.processes)
            let displaySnapshot = Snapshot(
                cpuPercent: snapshot.cpuPercent,
                attributedCpuPercent: processes.reduce(0) {
                    $0 + ($1.cpuPercent ?? 0)
                },
                cores: snapshot.cores,
                memory: snapshot.memory,
                disk: snapshot.disk,
                processes: processes
            )
            lastSnapshot = displaySnapshot
            updateTitle(displaySnapshot)
            if menuIsOpen {
                claudeSessions = ClaudeSessionStore.load(home: claudeHome)
                updateLive(displaySnapshot)
            }
            let decision = Derive.evaluateAlarms(snapshot: snapshot, thresholds: thresholds, previous: alarmState)
            alarmState = decision.state
            for kind in decision.triggered { Notifier.deliver(kind, snapshot: snapshot) }
        case let .failure(error):
            statusItem.button?.title = "err"
            lastSnapshot = nil
            guard !menuIsOpen else { return }
            menu.removeAllItems()
            dashboardView = nil
            claudeView = nil
            refreshHintView = nil
            groupRows = []
            memberRows = []
            menu.addItem(label(Printer.describe(error), color: Palette.coral))
            menu.addItem(.separator())
            menu.addItem(quitItem())
        }
    }

    private func render(_ snapshot: Snapshot) {
        menu.removeAllItems()
        dashboardView = nil
        claudeView = nil
        refreshHintView = nil
        groupRows = []
        memberRows = []
        mcpHeaderView = nil
        mcpRows = []

        menu.addItem(viewItem(VitalsHeaderView()))
        menu.addItem(.separator())

        let dashboard = VitalsDashboardView(snapshot: snapshot)
        dashboardView = dashboard
        menu.addItem(viewItem(dashboard))
        menu.addItem(.separator())

        if let model = claudeSectionModel() {
            let view = ClaudeSectionView(model: model)
            claudeView = view
            menu.addItem(viewItem(view))
            menu.addItem(.separator())
        }

        addMCPItems()

        menu.addItem(viewItem(ProcessHeaderView(showsNetwork: networkEnabled)))
        let processLimit = claudeSnapshot == nil ? 12 : 8
        let groups = rankedGroups(snapshot)
        for group in groups.prefix(processLimit) {
            menu.addItem(groupItem(group))
        }
        for track in lingeringTracks(excluding: groups).prefix(2) {
            menu.addItem(exitedItem(track))
        }

        menu.addItem(.separator())
        let hint = HintActionView(
            title: "Refresh Claude",
            hint: refreshHintText(),
            action: { [weak self] in
                guard let self else { return }
                self.claudeUsageSuspended = false
                self.refreshHintView?.setHint("Refreshing…")
                self.refresh()
                self.refreshClaude()
            }
        )
        refreshHintView = hint
        menu.addItem(viewItem(hint))
        menu.addItem(.separator())
        menu.addItem(networkToggleItem())
        menu.addItem(awakeMenuItem())
        menu.addItem(launchAtLoginItem())
        menu.addItem(.separator())
        menu.addItem(quitItem())
    }

    /// Re-read on every render (the menu is rebuilt on open), so an installer
    /// run or a System Settings change shows up without restarting.
    private func launchAtLoginItem() -> NSMenuItem {
        let state = LaunchAtLogin.state()
        let title = LaunchAtLogin.title(state)
        let item = NSMenuItem(title: title, action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        item.target = self
        switch state {
        case .enabled, .managedByLaunchd, .requiresApproval: item.state = .on
        case .disabled, .unavailable: item.state = .off
        }
        let locked = state == .managedByLaunchd || state == .unavailable
        item.isEnabled = !locked
        item.toolTip = state == .managedByLaunchd
            ? "The human-plugins installer keeps Vitals alive through \(LaunchAtLogin.agentLabel). Remove that agent to use a plain login item."
            : nil
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: locked ? Palette.secondary : Palette.primary
            ]
        )
        return item
    }

    @objc private func toggleLaunchAtLogin() {
        if case let .failure(error) = LaunchAtLogin.toggle() {
            Printer.err("launch at login: \(error.localizedDescription)")
        }
        if let lastSnapshot, menuIsOpen { render(lastSnapshot) }
    }

    private func networkToggleItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Network per process", action: #selector(toggleNetwork), keyEquivalent: "")
        item.target = self
        item.state = networkEnabled ? .on : .off
        item.toolTip = "Runs nettop every 2 s while the menu is open. Costs CPU, off by default."
        item.attributedTitle = NSAttributedString(
            string: "Network per process",
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: Palette.primary]
        )
        return item
    }

    // MARK: Stay awake

    /// Decide and (re)apply. Idempotent, runs every tick; the assertion
    /// holder only touches IOKit when the wanted state changed.
    private func applyAwake(_ context: PowerContext) {
        powerContext = context
        awakeDecision = Awake.decide(mode: awakeMode, context: context)
        awakeAssertions.apply(awakeDecision)
        if menuIsOpen { updateAwakeItem() }
    }

    private func awakeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Stay awake", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.appearance = NSAppearance(named: .darkAqua)
        for mode in AwakeMode.allCases {
            let choice = NSMenuItem(title: mode.title, action: #selector(chooseAwakeMode(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = mode.rawValue
            choice.state = mode == awakeMode ? .on : .off
            choice.attributedTitle = NSAttributedString(
                string: mode.title,
                attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: Palette.primary]
            )
            submenu.addItem(choice)
        }
        submenu.addItem(.separator())
        submenu.addItem(label("Holds PreventUserIdleSystemSleep and PreventUserIdleDisplaySleep and clears the"))
        submenu.addItem(label("kernel's clamshell-sleep flag (kPMSetClamshellSleepState), as Clamshell.app does."))
        submenu.addItem(label("Re-applied every 2 s and after a restart. Lid and display modes arm the flag only"))
        submenu.addItem(label("while an external display is attached; Always arms it regardless."))
        submenu.addItem(label("Clamshell.app flips the same flag: run one of the two, not both."))
        item.submenu = submenu
        awakeItem = item
        updateAwakeItem()
        return item
    }

    private func updateAwakeItem() {
        guard let awakeItem else { return }
        let holding = awakeAssertions.holdsSystem || awakeAssertions.holdsDisplay || awakeAssertions.overridesLidSleep
        let title = "Stay awake · \(awakeMode == .off ? "off" : awakeDecision.reason)"
            + (awakeAssertions.lastError.map { " · \($0)" } ?? "")
        let color: NSColor = awakeAssertions.lastError != nil
            ? Palette.coral
            : awakeDecision.warning ? Palette.amber : holding ? Palette.mint : Palette.primary
        awakeItem.title = title
        awakeItem.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: color]
        )
        awakeItem.state = holding ? .on : .off
        awakeItem.toolTip = "\(Awake.describe(powerContext)) · system \(awakeAssertions.holdsSystem ? "held" : "free") · display \(awakeAssertions.holdsDisplay ? "held" : "free") · lid-close sleep \(awakeAssertions.overridesLidSleep ? "off" : "on")"
    }

    @objc private func chooseAwakeMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = AwakeMode(rawValue: raw) else { return }
        awakeMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.awakeDefaultsKey)
        applyAwake(PowerSampler.context())
        if let lastSnapshot, menuIsOpen { render(lastSnapshot) }
    }

    @objc private func toggleNetwork() {
        networkEnabled.toggle()
        UserDefaults.standard.set(networkEnabled, forKey: Self.networkDefaultsKey)
        previousNetwork = nil
        networkRates = [:]
        menu.minimumWidth = menuWidth
        refresh()
    }

    private func claudeSectionModel() -> ClaudeSectionModel? {
        guard let claudeSnapshot else { return nil }
        return ClaudeSectionModel(
            telemetry: claudeSnapshot,
            sessions: claudeSessions,
            now: Date()
        )
    }

    /// System metrics are live every 2s; the hint tracks the slow path — the
    /// last Claude status/usage fetch — which is what "Refresh" actually redoes.
    private func refreshHintText() -> String {
        if claudeRefreshInFlight { return "Refreshing…" }
        guard let claudeSnapshot else { return "Not fetched yet" }
        let age = Format.age(since: claudeSnapshot.capturedAt)
        return age == "just now" ? "Updated just now" : "Updated \(age) ago"
    }

    private func updateLive(_ snapshot: Snapshot) {
        dashboardView?.update(snapshot)
        refreshHintView?.setHint(refreshHintText())
        if let claudeView, let model = claudeSectionModel(),
           !claudeView.update(model), let lastSnapshot {
            render(lastSnapshot)
            return
        }
        let groups = Dictionary(
            Derive.groups(snapshot.processes).map { ($0.root.pid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for row in groupRows {
            let series = history.series(row.identities)
            let peak = series.compactMap { $0 }.max()
            if let group = groups[row.pid] {
                row.view.update(
                    cpu: group.cpuPercent, mem: group.footprintBytes, name: groupName(group),
                    exited: false, peak: peak, series: normalized(series),
                    net: Network.groupRate(pids: group.members.map(\.pid), in: networkRates)
                )
            } else {
                row.view.update(
                    cpu: nil, mem: nil, name: "\(row.name)  exited",
                    exited: true, peak: peak, series: normalized(series), net: nil
                )
            }
        }
        let views = Dictionary(
            snapshot.processes.map { ($0.pid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for row in memberRows {
            if let view = views[row.pid] {
                setRowText(row.item, cpu: view.cpuPercent, mem: view.footprintBytes, name: memberName(view))
            } else {
                setRowText(row.item, cpu: nil, mem: nil, name: "\(row.name)  [\(row.pid)]  exited")
            }
        }
    }

    private func refreshClaude() {
        guard !claudeRefreshInFlight else { return }
        claudeRefreshInFlight = true
        let includeUsage = !claudeUsageSuspended
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.claudeTelemetry.fetch(includeUsage: includeUsage)
            if snapshot.usage.isAccessDenied {
                self.claudeUsageSuspended = true
            }
            self.claudeRefreshInFlight = false
            self.applyClaude(snapshot)
        }
    }

    private func applyClaude(_ snapshot: ClaudeTelemetrySnapshot) {
        let decision = ClaudeAlerts.evaluate(snapshot: snapshot, previous: claudeAlertState)
        claudeAlertState = decision.state
        claudeSnapshot = snapshot
        for alert in decision.triggered {
            Notifier.deliver(alert)
        }
        guard menuIsOpen, let lastSnapshot else { return }
        refreshHintView?.setHint(refreshHintText())
        if let claudeView, let model = claudeSectionModel(), claudeView.update(model) {
            return
        }
        render(lastSnapshot)
    }

    private func updateTitle(_ snapshot: Snapshot) {
        let cpuFraction = normalizedCPU(snapshot)
        let availGiB = Double(snapshot.memory.available) / 1_073_741_824.0
        let diskAvailableGB = Double(snapshot.disk.available) / 1_000_000_000.0
        let diskFreeGB = Double(snapshot.disk.free) / 1_000_000_000.0
        let ramState = switch snapshot.memory.pressure {
        case .green: "RAM OK"
        case .yellow: "RAM WARN"
        case .red: "RAM CRIT"
        }
        let diskAvailable = diskAvailableGB >= 10
            ? String(format: "%.0fG", diskAvailableGB)
            : String(format: "%.1fG", diskAvailableGB)
        let diskUsedFraction = snapshot.disk.total == 0
            ? 0
            : 1 - Double(snapshot.disk.available) / Double(snapshot.disk.total)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .medium)
        let title = NSMutableAttributedString(
            string: String(format: " %.0f%%", cpuFraction * 100),
            attributes: [.foregroundColor: Palette.usage(cpuFraction), .font: font]
        )
        title.append(NSAttributedString(
            string: "  ",
            attributes: [.foregroundColor: Palette.secondary, .font: font]
        ))
        title.append(NSAttributedString(
            string: ramState,
            attributes: [.foregroundColor: Palette.pressure(snapshot.memory.pressure), .font: font]
        ))
        title.append(NSAttributedString(
            string: "  ",
            attributes: [.foregroundColor: Palette.secondary, .font: font]
        ))
        title.append(NSAttributedString(
            string: "SSD \(diskAvailable)",
            attributes: [.foregroundColor: Palette.usage(diskUsedFraction), .font: font]
        ))
        statusItem.button?.attributedTitle = title
        statusItem.button?.toolTip = String(
            format: "CPU %.0f%% · RAM pressure %@ · %.1f GiB available · %.1f GB SSD available · %.1f GB free now",
            cpuFraction * 100,
            snapshot.memory.pressure.rawValue,
            availGiB,
            diskAvailableGB,
            diskFreeGB
        )
    }

    private func normalizedCPU(_ snapshot: Snapshot) -> Double {
        let capacity = Double(max(snapshot.cores, 1)) * 100
        return clamped((snapshot.cpuPercent ?? 0) / capacity)
    }

    /// Groups ordered by their 60 s window peak, so a process that spiked ten
    /// samples ago stays where the eye left it instead of dropping to the
    /// bottom the moment it goes quiet.
    private func rankedGroups(_ snapshot: Snapshot) -> [ProcessGroup] {
        Derive.groups(snapshot.processes)
            .map { group in (group, history.peak(group.members.map(ProcessCPUHistory.Identity.init))) }
            .sorted { lhs, rhs in
                guard lhs.1 == rhs.1 else { return lhs.1 > rhs.1 }
                return (lhs.0.cpuPercent ?? -1) > (rhs.0.cpuPercent ?? -1)
            }
            .map(\.0)
    }

    /// Exited processes still inside their grace window, most notable first.
    /// Only ones that did something (peak >= 5%) earn a lingering row.
    private func lingeringTracks(excluding groups: [ProcessGroup]) -> [ProcessCPUHistory.Track] {
        let live = Set(groups.flatMap { $0.members.map(\.pid) })
        return history.tracks().filter { !$0.isAlive && $0.peak >= 5 && !live.contains($0.last.pid) }
    }

    private func exitedItem(_ track: ProcessCPUHistory.Track) -> NSMenuItem {
        let view = ProcessRowView(showsNetwork: networkEnabled)
        view.update(
            cpu: nil, mem: nil, name: "\(track.last.name)  exited",
            exited: true, peak: track.peak, series: normalized(track.samples), net: nil
        )
        groupRows.append((
            pid: track.last.pid, name: track.last.name,
            identities: [ProcessCPUHistory.Identity(track.last)], view: view
        ))
        let item = viewItem(view)
        item.isEnabled = false
        return item
    }

    /// Percent of one core to sparkline units (1.0 = one full core).
    private func normalized(_ series: [Double?]) -> [Double?] {
        series.map { $0.map { $0 / 100 } }
    }

    private func groupName(_ group: ProcessGroup) -> String {
        group.members.count > 1 ? "\(group.root.name)  ×\(group.members.count)" : group.root.name
    }

    private func memberName(_ process: ProcessView) -> String {
        "\(process.name)  [\(process.pid)]"
    }

    private func groupItem(_ group: ProcessGroup) -> NSMenuItem {
        let identities = group.members.map(ProcessCPUHistory.Identity.init)
        let series = history.series(identities)
        let view = ProcessRowView(showsNetwork: networkEnabled)
        view.update(
            cpu: group.cpuPercent, mem: group.footprintBytes, name: groupName(group),
            exited: false, peak: series.compactMap { $0 }.max(), series: normalized(series),
            net: Network.groupRate(pids: group.members.map(\.pid), in: networkRates)
        )
        groupRows.append((pid: group.root.pid, name: group.root.name, identities: identities, view: view))
        let item = viewItem(view)
        if group.members.count == 1 {
            item.submenu = actionMenu(for: group.root.pid)
        } else {
            let submenu = NSMenu()
            for member in group.members.prefix(20) {
                submenu.addItem(memberItem(member))
            }
            if group.members.count > 20 {
                submenu.addItem(label("… \(group.members.count - 20) more"))
            }
            item.submenu = submenu
        }
        return item
    }

    private func memberItem(_ process: ProcessView) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        setRowText(item, cpu: process.cpuPercent, mem: process.footprintBytes, name: memberName(process))
        memberRows.append((pid: process.pid, name: process.name, item: item))
        item.submenu = actionMenu(for: process.pid)
        return item
    }

    private func setRowText(_ item: NSMenuItem, cpu: Double?, mem: UInt64?, name: String) {
        let exited = name.hasSuffix("exited")
        let cpuText = cpu.map { String(format: "%.0f%%", $0) } ?? "--"
        let memText = mem.map(compactBytes) ?? "--"
        let title = "\(pad(cpuText, 5))  \(pad(memText, 6))  \(name)"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let attributed = NSMutableAttributedString(
            string: pad(cpuText, 5),
            attributes: [
                .font: font,
                .foregroundColor: cpu.map(Palette.processCPU) ?? Palette.secondary
            ]
        )
        attributed.append(NSAttributedString(
            string: "  \(pad(memText, 6))  ",
            attributes: [.font: font, .foregroundColor: mem == nil ? Palette.secondary : Palette.mint]
        ))
        let nameFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        attributed.append(NSAttributedString(
            string: name,
            attributes: [
                .font: exited ? NSFontManager.shared.convert(nameFont, toHaveTrait: .italicFontMask) : nameFont,
                .foregroundColor: exited ? Palette.coral.withAlphaComponent(0.7) : Palette.primary
            ]
        ))
        item.title = title
        item.attributedTitle = attributed
    }

    private func actionMenu(for pid: Int32) -> NSMenu {
        let submenu = NSMenu()
        submenu.appearance = NSAppearance(named: .darkAqua)
        submenu.addItem(action("Stop (freeze, keep RAM)", #selector(stop(_:)), pid, color: Palette.amber))
        submenu.addItem(action("Resume", #selector(resume(_:)), pid, color: Palette.mint))
        submenu.addItem(.separator())
        submenu.addItem(action("Interrupt (graceful)", #selector(interrupt(_:)), pid, color: Palette.blue))
        submenu.addItem(action("Kill (force)", #selector(force(_:)), pid, color: Palette.coral))
        return submenu
    }

    private func action(_ title: String, _ selector: Selector, _ pid: Int32, color: NSColor) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = NSNumber(value: pid)
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: color]
        )
        return item
    }

    private func label(_ text: String, color: NSColor = Palette.secondary) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: color]
        )
        item.isEnabled = false
        return item
    }

    /// Item views are created at the default 352 pt; the menu takes its width
    /// from them, so they are widened here when the NET column is on.
    private func viewItem(_ view: NSView) -> NSMenuItem {
        view.frame.size.width = menuWidth
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }

    private func quitItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Quit Vitals", action: #selector(quit), keyEquivalent: "q")
        item.target = self
        item.attributedTitle = NSAttributedString(
            string: "Quit Vitals",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: Palette.primary
            ]
        )
        return item
    }

    @objc private func stop(_ sender: NSMenuItem) { fire(Signals.stop, sender) }
    @objc private func resume(_ sender: NSMenuItem) { fire(Signals.resume, sender) }
    @objc private func interrupt(_ sender: NSMenuItem) { fire(Signals.interrupt, sender) }
    @objc private func force(_ sender: NSMenuItem) { fire(Signals.force, sender) }

    private func fire(_ signal: Int32, _ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSNumber else { return }
        _ = Signals.send(signal, to: value.int32Value)
        refresh()
    }

    @objc private func quit() {
        // The assertions die with the process; the kernel flag would not.
        awakeAssertions.releaseAll()
        NSApplication.shared.terminate(nil)
    }
}

private struct UsageRowModel {
    let label: String
    let fraction: Double
    let detail: String
}

private struct UsageMenuModel {
    let pressure: Pressure
    let rows: [UsageRowModel]

    init(snapshot: Snapshot) {
        let cpuFraction = clamped(
            (snapshot.cpuPercent ?? 0) / (Double(max(snapshot.cores, 1)) * 100)
        )
        let memoryFraction = fraction(snapshot.memory.used, of: snapshot.memory.total)
        let diskUsed = snapshot.disk.total >= snapshot.disk.available
            ? snapshot.disk.total - snapshot.disk.available
            : 0

        pressure = snapshot.memory.pressure
        rows = [
            UsageRowModel(
                label: "CPU",
                fraction: cpuFraction,
                detail: String(
                    format: "%.0f%% · %.0f%% aggregate",
                    cpuFraction * 100,
                    snapshot.cpuPercent ?? 0
                )
            ),
            UsageRowModel(
                label: "Memory",
                fraction: memoryFraction,
                detail: "\(compactBytes(snapshot.memory.used)) used · \(compactBytes(snapshot.memory.available)) available"
            ),
            UsageRowModel(
                label: "Disk",
                fraction: fraction(diskUsed, of: snapshot.disk.total),
                detail: "\(compactDiskBytes(snapshot.disk.available)) available · \(compactDiskBytes(snapshot.disk.free)) free now"
            )
        ]
    }
}

@MainActor
private final class VitalsHeaderView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Vitals")
    private let subtitleLabel = NSTextField(labelWithString: "System telemetry | updates every 2s")
    private let liveBadge = NSTextField(labelWithString: "LIVE")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 352, height: 58))

        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = Palette.primary
        subtitleLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        subtitleLabel.textColor = Palette.secondary

        liveBadge.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        liveBadge.textColor = Palette.mint
        liveBadge.alignment = .center
        liveBadge.drawsBackground = true
        liveBadge.backgroundColor = Palette.mint.withAlphaComponent(0.13)
        liveBadge.wantsLayer = true
        liveBadge.layer?.cornerRadius = 9
        liveBadge.layer?.masksToBounds = true

        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(liveBadge)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 16, y: 30, width: bounds.width - 100, height: 18)
        subtitleLabel.frame = NSRect(x: 16, y: 13, width: bounds.width - 32, height: 15)
        liveBadge.frame = NSRect(x: bounds.width - 66, y: 27, width: 50, height: 18)
    }
}

@MainActor
private final class VitalsDashboardView: NSView {
    private let sectionLabel = NSTextField(labelWithString: "SYSTEM HEALTH")
    private let pressureBadge = NSTextField(labelWithString: "")
    private let cpuRow = MetricBarView()
    private let memoryRow = MetricBarView()
    private let diskRow = MetricBarView()

    init(snapshot: Snapshot) {
        super.init(frame: NSRect(x: 0, y: 0, width: 352, height: 164))

        sectionLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        sectionLabel.textColor = Palette.secondary

        pressureBadge.font = NSFont.systemFont(ofSize: 9.5, weight: .bold)
        pressureBadge.alignment = .center
        pressureBadge.drawsBackground = true
        pressureBadge.wantsLayer = true
        pressureBadge.layer?.cornerRadius = 8
        pressureBadge.layer?.masksToBounds = true

        addSubview(sectionLabel)
        addSubview(pressureBadge)
        addSubview(cpuRow)
        addSubview(memoryRow)
        addSubview(diskRow)
        update(snapshot)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func update(_ snapshot: Snapshot) {
        let model = UsageMenuModel(snapshot: snapshot)
        for (view, row) in zip([cpuRow, memoryRow, diskRow], model.rows) {
            view.update(
                title: row.label,
                detail: row.detail,
                fraction: row.fraction,
                color: Palette.usage(row.fraction)
            )
        }

        let pressureColor = Palette.pressure(model.pressure)
        pressureBadge.stringValue = model.pressure.rawValue.uppercased()
        pressureBadge.textColor = pressureColor
        pressureBadge.backgroundColor = pressureColor.withAlphaComponent(0.13)
    }

    override func layout() {
        super.layout()
        sectionLabel.frame = NSRect(x: 16, y: 141, width: bounds.width - 110, height: 14)
        pressureBadge.frame = NSRect(x: bounds.width - 76, y: 137, width: 60, height: 17)
        cpuRow.frame = NSRect(x: 16, y: 93, width: bounds.width - 32, height: 42)
        memoryRow.frame = NSRect(x: 16, y: 49, width: bounds.width - 32, height: 42)
        diskRow.frame = NSRect(x: 16, y: 5, width: bounds.width - 32, height: 42)
    }
}

@MainActor
final class MetricBarView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let track = NSView()
    private let fill = NSView()
    private var progress = 0.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = Palette.primary
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        detailLabel.textColor = Palette.secondary
        detailLabel.alignment = .right
        detailLabel.lineBreakMode = .byTruncatingHead

        track.wantsLayer = true
        track.layer?.backgroundColor = Palette.track.cgColor
        track.layer?.cornerRadius = 4
        track.layer?.masksToBounds = true
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 4
        fill.layer?.masksToBounds = true

        track.addSubview(fill)
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(track)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func update(title: String, detail: String, fraction: Double, color: NSColor) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        progress = clamped(fraction)
        fill.layer?.backgroundColor = color.cgColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let gap = 8.0
        let minimumTitleWidth = 72.0
        let measuredDetailWidth = (detailLabel.stringValue as NSString).size(
            withAttributes: [.font: detailLabel.font as Any]
        ).width + 12
        let detailWidth = min(
            ceil(measuredDetailWidth),
            max(0, bounds.width - minimumTitleWidth - gap)
        )
        let titleWidth = max(0, bounds.width - detailWidth - gap)
        titleLabel.frame = NSRect(x: 0, y: 22, width: titleWidth, height: 17)
        detailLabel.frame = NSRect(
            x: titleWidth + gap,
            y: 22,
            width: detailWidth,
            height: 16
        )
        track.frame = NSRect(x: 0, y: 6, width: bounds.width, height: 8)
        fill.frame = NSRect(x: 0, y: 0, width: track.bounds.width * progress, height: track.bounds.height)
    }
}

@MainActor
private final class HintActionView: NSView {
    private let titleLabel: NSTextField
    private let hintLabel: NSTextField
    private let action: @MainActor () -> Void
    private var tracking: NSTrackingArea?

    init(title: String, hint: String, action: @escaping @MainActor () -> Void) {
        titleLabel = NSTextField(labelWithString: title)
        hintLabel = NSTextField(labelWithString: hint)
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 352, height: 34))

        wantsLayer = true
        layer?.cornerRadius = 6

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = Palette.primary

        hintLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        hintLabel.textColor = Palette.secondary
        hintLabel.alignment = .center
        hintLabel.drawsBackground = true
        hintLabel.backgroundColor = Palette.track
        hintLabel.wantsLayer = true
        hintLabel.layer?.cornerRadius = 9
        hintLabel.layer?.masksToBounds = true

        addSubview(titleLabel)
        addSubview(hintLabel)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(performAction)))
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func setHint(_ text: String) {
        hintLabel.stringValue = text
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let hintWidth = min(
            max(ceil((hintLabel.stringValue as NSString).size(
                withAttributes: [.font: hintLabel.font as Any]
            ).width) + 20, 72),
            bounds.width - 180
        )
        titleLabel.frame = NSRect(x: 16, y: 8, width: 150, height: 18)
        hintLabel.frame = NSRect(x: bounds.width - 16 - hintWidth, y: 8, width: hintWidth, height: 18)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(next)
        tracking = next
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = Palette.primary.withAlphaComponent(0.08).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @objc private func performAction() {
        action()
    }
}

@MainActor
private final class ProcessHeaderView: NSView {
    private let cpuLabel = NSTextField(labelWithString: "CPU")
    private let memoryLabel = NSTextField(labelWithString: "MEMORY")
    private let processLabel = NSTextField(labelWithString: "TOP PROCESSES")
    private let windowLabel = NSTextField(labelWithString: "60S")
    private let networkLabel = NSTextField(labelWithString: "NET ↓↑ /S")
    private let showsNetwork: Bool

    init(showsNetwork: Bool) {
        self.showsNetwork = showsNetwork
        super.init(frame: NSRect(x: 0, y: 0, width: 352, height: 28))

        cpuLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)
        memoryLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)
        processLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        cpuLabel.textColor = Palette.secondary
        memoryLabel.textColor = Palette.secondary
        processLabel.textColor = Palette.secondary
        cpuLabel.alignment = .right
        memoryLabel.alignment = .right

        windowLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)
        windowLabel.textColor = Palette.secondary
        windowLabel.alignment = .right
        networkLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)
        networkLabel.textColor = Palette.secondary
        networkLabel.alignment = .right
        networkLabel.isHidden = !showsNetwork
        addSubview(networkLabel)

        addSubview(cpuLabel)
        addSubview(memoryLabel)
        addSubview(processLabel)
        addSubview(windowLabel)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()
        cpuLabel.frame = NSRect(x: 16, y: 6, width: 36, height: 14)
        memoryLabel.frame = NSRect(x: 60, y: 6, width: 52, height: 14)
        let sparkX = bounds.width - 16 - ProcessRowView.sparklineWidth
        let netX = sparkX - 8 - ProcessRowView.networkWidth
        let nameEnd = showsNetwork ? netX : sparkX
        processLabel.frame = NSRect(x: 124, y: 6, width: max(0, nameEnd - 124 - 10), height: 14)
        networkLabel.frame = NSRect(x: netX, y: 6, width: ProcessRowView.networkWidth, height: 14)
        windowLabel.frame = NSRect(x: sparkX, y: 6, width: ProcessRowView.sparklineWidth, height: 14)
    }
}

@MainActor
enum Palette {
    static let primary = NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1)
    static let secondary = NSColor(srgbRed: 0.61, green: 0.63, blue: 0.68, alpha: 1)
    static let track = NSColor.white.withAlphaComponent(0.10)
    static let blue = NSColor(srgbRed: 0.16, green: 0.53, blue: 1.00, alpha: 1)
    static let amber = NSColor(srgbRed: 1.00, green: 0.67, blue: 0.08, alpha: 1)
    static let mint = NSColor(srgbRed: 0.20, green: 0.82, blue: 0.62, alpha: 1)
    static let coral = NSColor(srgbRed: 1.00, green: 0.35, blue: 0.38, alpha: 1)

    static func usage(_ fraction: Double) -> NSColor {
        if fraction >= 0.90 { return coral }
        if fraction >= 0.70 { return amber }
        return blue
    }

    static func pressure(_ pressure: Pressure) -> NSColor {
        switch pressure {
        case .green: mint
        case .yellow: amber
        case .red: coral
        }
    }

    static func processCPU(_ percent: Double) -> NSColor {
        if percent >= 100 { return coral }
        if percent >= 50 { return amber }
        return blue
    }
}

private func clamped(_ value: Double) -> Double {
    min(max(value, 0), 1)
}

private func fraction(_ numerator: UInt64, of denominator: UInt64) -> Double {
    guard denominator > 0 else { return 0 }
    return clamped(Double(numerator) / Double(denominator))
}

private func compactDiskBytes(_ bytes: UInt64) -> String {
    String(format: "%.1f GB", Double(bytes) / 1_000_000_000.0)
}

/// Wraps a closure for `NSMenuItem.representedObject`.
@MainActor
private final class MCPActionBox: NSObject {
    let handler: @MainActor () -> Void
    init(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
}
