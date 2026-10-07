import AppKit
import VitalsClaude

/// Everything the Claude section renders. Built from the network snapshot
/// (status + usage, refreshed every 60s) and the local session registry
/// (refreshed with the 2s system tick). Add future `.claude` data here.
struct ClaudeSectionModel: Equatable {
    let telemetry: ClaudeTelemetrySnapshot
    let sessions: ClaudeSessionsSnapshot
    let now: Date
    /// By pid; tokens the session's transcript shows for the last 15 minutes
    /// and the subagents it started.
    var burns: [Int32: SessionBurn] = [:]
    /// By pid; prompt cache of the main thread and of recent subagents.
    var caches: [Int32: SessionCache] = [:]
    /// By pid; desktop sessions bound to a PR with Auto-fix on.
    var autoFix: [Int32: AutoFixSession] = [:]
    /// By pid; RAM and CPU from the 2 s sample.
    var processes: [Int32: ProcessUsage] = [:]

    static let usageRowHeight = 44.0
    static let messageHeight = 34.0
    static let headerHeight = 30.0
    static let sessionsHeaderHeight = 22.0
    static let sessionRowHeight = 22.0
    static let detailLineHeight = 14.0
    /// Width a detail line can use before it wraps to a second row.
    static let detailWidth = 320.0 - 13
    @MainActor static let detailFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    static let bottomPadding = 6.0
    static let maxSessionRows = 6

    var visibleSessions: [ClaudeSession] {
        Array(sessions.sessions.prefix(Self.maxSessionRows))
    }

    var hiddenSessionCount: Int {
        max(0, sessions.sessions.count - Self.maxSessionRows)
    }

    /// Menu item views cannot resize while the menu is open, so the controller
    /// re-renders when this changes.
    @MainActor
    var layoutSignature: String {
        "\(telemetry.usage.rows.count)/\(visibleSessions.map { "\(detailRows($0))" }.joined(separator: ","))/\(hiddenSessionCount > 0)"
    }

    @MainActor
    var height: CGFloat {
        var height = Self.headerHeight
        let usageRows = telemetry.usage.rows.count
        height += usageRows > 0
            ? Double(usageRows) * Self.usageRowHeight
            : Self.messageHeight
        height += Self.sessionsHeaderHeight
        height += visibleSessions.reduce(0) { $0 + rowHeight($1) }
        if hiddenSessionCount > 0 {
            height += Self.sessionRowHeight
        }
        height += Self.bottomPadding
        return height
    }

    @MainActor
    func rowHeight(_ session: ClaudeSession) -> CGFloat {
        Self.sessionRowHeight + Double(detailRows(session)) * Self.detailLineHeight
    }

    @MainActor
    func detailRows(_ session: ClaudeSession) -> Int {
        detailLines(session).reduce(0) { $0 + $1.rows }
    }

    func autoFixState(_ session: ClaudeSession) -> AutoFixState? {
        autoFix[session.pid].map { AutoFix.state($0, busy: session.status == .busy) }
    }

    /// Lines under the registry line: auto-fix details, the prompt cache,
    /// one hint, one line per recent subagent.
    @MainActor
    func detailLines(_ session: ClaudeSession) -> [SessionLine] {
        var lines: [SessionLine] = []
        if let fix = autoFix[session.pid], let state = autoFixState(session) {
            lines.append(SessionLine(segments: [
                .init(state.label, Palette.autoFix(state)),
                .init(" · " + AutoFix.reference(fix.pr), Palette.detail)
            ]))
            lines.append(SessionLine(AutoFix.checks(fix), Palette.detail))
            var process = AutoFix.event(fix.activity, now: now, working: state == .working) + " · pid \(session.pid)"
            if let usage = processes[session.pid] {
                process += " · \(Format.megabytes(usage.footprintBytes)) · \(String(format: "%.1f", usage.cpuPercent ?? 0))% CPU"
            }
            lines.append(SessionLine(process, Palette.detail))
        }
        guard let cache = caches[session.pid], let main = cache.main else { return lines.map(Self.measured) }
        lines.append(cacheLine(PromptCacheText.line(main, now: now), main))
        if let hint = cache.hint {
            lines.append(SessionLine(hint, Palette.detail))
        }
        for subagent in cache.subagents {
            lines.append(cacheLine(PromptCacheText.subagentLine(subagent, now: now), subagent.cache, indent: 10))
        }
        return lines.map(Self.measured)
    }

    /// Long lines wrap to a second row instead of hiding their end.
    @MainActor
    private static func measured(_ line: SessionLine) -> SessionLine {
        var line = line
        let width = (line.plain as NSString).size(withAttributes: [.font: detailFont]).width
        line.rows = width > detailWidth - line.indent ? 2 : 1
        return line
    }

    /// Green while warm, yellow under a fifth of the TTL, red when cold.
    /// Differentiate Without Color adds the word as well. The bar's empty
    /// cells are dimmed: at this size "░" looks nearly solid.
    @MainActor
    private func cacheLine(_ text: String, _ cache: PromptCache, indent: CGFloat = 0) -> SessionLine {
        let color: NSColor
        var text = text
        if !cache.isWarm(now: now) {
            color = Palette.coral
        } else if cache.isExpiring(now: now) {
            color = Palette.amber
            if Palette.differentiateWithoutColor { text += " · expiring" }
        } else {
            color = Palette.mint
        }
        var segments: [SessionLine.Segment] = []
        var run = ""
        var runIsEmptyCell = false
        for character in text {
            let emptyCell = character == "░"
            if emptyCell != runIsEmptyCell, !run.isEmpty {
                segments.append(.init(run, runIsEmptyCell ? color.withAlphaComponent(0.3) : color))
                run = ""
            }
            runIsEmptyCell = emptyCell
            run.append(character)
        }
        segments.append(.init(run, runIsEmptyCell ? color.withAlphaComponent(0.3) : color))
        return SessionLine(segments: segments, indent: indent)
    }

    /// Hover text: effective TTL and where it came from, expiry, request counts.
    func cacheTooltip(_ session: ClaudeSession) -> String? {
        guard let cache = caches[session.pid], let main = cache.main else { return nil }
        let source: String
        switch main.ttlSource {
        case .observed: source = "from the cache bucket the last request wrote"
        case .setting: source = "from promptCacheTtl / CLAUDE_CODE_PROMPT_CACHE_TTL"
        case .standard: source = "default for the main conversation"
        }
        let clock = DateFormatter.localizedString(from: main.expiresAt, dateStyle: .none, timeStyle: .short)
        var text = "prompt cache: TTL \(PromptCacheText.ttl(main.ttl)) \(source); "
            + (main.isWarm(now: now) ? "expires \(clock)" : "went cold \(clock)")
            + "; \(main.requests) requests, hit \(Int((main.hitRatio * 100).rounded()))%, \(main.misses) misses"
        if main.missRecacheTokens > 0 { text += " re-paid \(PromptCacheText.kilo(main.missRecacheTokens))" }
        if !cache.subagents.isEmpty { text += "\nsubagents get 5m unless subagentPromptCacheTtl says otherwise" }
        return text
    }
}

struct ProcessUsage: Equatable {
    let cpuPercent: Double?
    let footprintBytes: UInt64?
}

/// One line of a session row, in one or more colors.
struct SessionLine: Equatable {
    struct Segment: Equatable {
        let text: String
        let color: NSColor

        init(_ text: String, _ color: NSColor) {
            self.text = text
            self.color = color
        }
    }

    let segments: [Segment]
    var indent: CGFloat = 0
    /// 1, or 2 when the text wraps.
    var rows = 1

    init(segments: [Segment], indent: CGFloat = 0) {
        self.segments = segments
        self.indent = indent
    }

    init(_ text: String, _ color: NSColor, indent: CGFloat = 0) {
        self.init(segments: [Segment(text, color)], indent: indent)
    }

    var plain: String { segments.map(\.text).joined() }

    func attributed(_ font: NSFont) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = rows > 1 ? .byWordWrapping : .byTruncatingTail
        let result = NSMutableAttributedString()
        for segment in segments {
            result.append(NSAttributedString(string: segment.text, attributes: [
                .foregroundColor: segment.color, .font: font, .paragraphStyle: paragraph
            ]))
        }
        return result
    }
}

@MainActor
final class ClaudeSectionView: NSView {
    private let sectionLabel = NSTextField(labelWithString: "CLAUDE")
    private let statusBadge = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let sessionsLabel = NSTextField(labelWithString: "SESSIONS")
    private let sessionsDetail = NSTextField(labelWithString: "")
    private let copyAllLabel = FlashLabel(text: "COPY ALL")
    private let moreLabel = NSTextField(labelWithString: "")
    private var usageRows: [MetricBarView] = []
    private var sessionRows: [ClaudeSessionRowView] = []
    private var model: ClaudeSectionModel

    init(model: ClaudeSectionModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 352, height: model.height))

        sectionLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        sectionLabel.textColor = Palette.secondary

        statusBadge.font = NSFont.systemFont(ofSize: 9.5, weight: .bold)
        statusBadge.alignment = .center
        statusBadge.drawsBackground = true
        statusBadge.wantsLayer = true
        statusBadge.layer?.cornerRadius = 8
        statusBadge.layer?.masksToBounds = true

        messageLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        messageLabel.textColor = Palette.secondary
        messageLabel.alignment = .center

        sessionsLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        sessionsLabel.textColor = Palette.secondary
        sessionsDetail.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        sessionsDetail.textColor = Palette.secondary
        sessionsDetail.alignment = .right

        moreLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        moreLabel.textColor = Palette.secondary

        copyAllLabel.toolTip = "Copy every session, including hidden ones, one line each"
        copyAllLabel.onClick = { [weak self] in
            guard let self else { return }
            Clipboard.copy(ClaudeSessionText.lines(self.model.sessions.sessions))
        }

        addSubview(sectionLabel)
        addSubview(statusBadge)
        addSubview(messageLabel)
        addSubview(sessionsLabel)
        addSubview(sessionsDetail)
        addSubview(copyAllLabel)
        addSubview(moreLabel)
        rebuildRows()
        apply()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// Returns `false` when the new model needs a different number of rows;
    /// the caller must then rebuild the menu item.
    @discardableResult
    func update(_ model: ClaudeSectionModel) -> Bool {
        let sameShape = model.layoutSignature == self.model.layoutSignature
        self.model = model
        guard sameShape else { return false }
        apply()
        return true
    }

    private func rebuildRows() {
        usageRows.forEach { $0.removeFromSuperview() }
        sessionRows.forEach { $0.removeFromSuperview() }
        usageRows = model.telemetry.usage.rows.map { _ in MetricBarView() }
        sessionRows = model.visibleSessions.map { _ in ClaudeSessionRowView() }
        usageRows.forEach(addSubview)
        sessionRows.forEach(addSubview)
    }

    private func apply() {
        let health = model.telemetry.health
        let color: NSColor
        switch health.level {
        case .operational: color = Palette.mint
        case .degraded: color = Palette.amber
        case .outage: color = Palette.coral
        case .unavailable: color = Palette.secondary
        }
        statusBadge.stringValue = health.label
        statusBadge.textColor = color
        statusBadge.backgroundColor = color.withAlphaComponent(0.13)
        statusBadge.toolTip = health.hoverText

        for (view, row) in zip(usageRows, model.telemetry.usage.rows) {
            view.update(
                title: row.label,
                detail: row.detail,
                fraction: row.fraction,
                color: Palette.usage(row.fraction)
            )
        }
        if let unavailable = model.telemetry.usage.unavailableMessage {
            messageLabel.stringValue = unavailable
            messageLabel.textColor = Palette.secondary
            messageLabel.isHidden = false
            messageLabel.toolTip = nil
        } else {
            messageLabel.isHidden = true
        }

        let sessions = model.sessions
        let busy = sessions.busyCount
        sessionsDetail.stringValue = sessions.sessions.isEmpty
            ? "none running"
            : "\(busy) busy · \(sessions.sessions.count - busy) idle"
        sessionsDetail.textColor = busy > 0 ? Palette.blue : Palette.secondary
        copyAllLabel.isHidden = sessions.sessions.isEmpty
        for (view, session) in zip(sessionRows, model.visibleSessions) {
            view.update(
                session, now: model.now, burn: model.burns[session.pid],
                lines: model.detailLines(session),
                autoFix: model.autoFix[session.pid].flatMap { fix in model.autoFixState(session).map { (fix, $0) } },
                cacheTooltip: model.cacheTooltip(session)
            )
        }
        moreLabel.stringValue = model.hiddenSessionCount > 0
            ? "… \(model.hiddenSessionCount) more"
            : ""
        moreLabel.isHidden = model.hiddenSessionCount == 0
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let inset = 16.0
        let contentWidth = width - inset * 2
        var y = bounds.height - ClaudeSectionModel.headerHeight

        sectionLabel.frame = NSRect(x: inset, y: y + 8, width: contentWidth - 116, height: 14)
        statusBadge.frame = NSRect(x: width - 112, y: y + 4, width: 96, height: 17)

        if usageRows.isEmpty {
            y -= ClaudeSectionModel.messageHeight
            messageLabel.frame = NSRect(x: inset, y: y, width: contentWidth, height: 34)
        } else {
            for row in usageRows {
                y -= ClaudeSectionModel.usageRowHeight
                row.frame = NSRect(x: inset, y: y + 2, width: contentWidth, height: 42)
            }
        }

        y -= ClaudeSectionModel.sessionsHeaderHeight
        let copyWidth = 66.0
        sessionsLabel.frame = NSRect(x: inset, y: y + 2, width: 100, height: 14)
        sessionsDetail.frame = NSRect(x: inset + 100, y: y + 2, width: contentWidth - 100 - copyWidth - 8, height: 14)
        copyAllLabel.frame = NSRect(x: width - inset - copyWidth, y: y, width: copyWidth, height: 18)

        for (row, session) in zip(sessionRows, model.visibleSessions) {
            let height = model.rowHeight(session)
            y -= height
            row.frame = NSRect(x: inset, y: y, width: contentWidth, height: height)
        }
        if model.hiddenSessionCount > 0 {
            y -= ClaudeSectionModel.sessionRowHeight
            moreLabel.frame = NSRect(x: inset + 16, y: y + 3, width: contentWidth - 16, height: 15)
        }
    }
}

@MainActor
final class ClaudeSessionRowView: NSView {
    private let dot = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let marker = NSTextField(labelWithString: "")
    private let cwdLabel = NSTextField(labelWithString: "")
    private let ageLabel = NSTextField(labelWithString: "")
    private var lineLabels: [NSTextField] = []
    private var lines: [SessionLine] = []
    private var session: ClaudeSession?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 22))

        wantsLayer = true
        layer?.cornerRadius = 5
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(copySession)))

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5

        nameLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        nameLabel.textColor = Palette.primary
        nameLabel.lineBreakMode = .byTruncatingTail

        marker.font = NSFont.systemFont(ofSize: 9, weight: .bold)
        marker.alignment = .center
        marker.drawsBackground = true
        marker.wantsLayer = true
        marker.layer?.cornerRadius = 7
        marker.layer?.masksToBounds = true
        marker.isHidden = true

        cwdLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        cwdLabel.textColor = Palette.secondary
        cwdLabel.lineBreakMode = .byTruncatingHead

        ageLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        ageLabel.textColor = Palette.secondary
        ageLabel.alignment = .right

        addSubview(dot)
        addSubview(nameLabel)
        addSubview(marker)
        addSubview(cwdLabel)
        addSubview(ageLabel)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    @objc private func copySession() {
        guard let session else { return }
        Clipboard.copy(([ClaudeSessionText.line(session)] + lines.map(\.plain)).joined(separator: "\n"))
        flash(self)
    }

    func update(
        _ session: ClaudeSession, now: Date, burn: SessionBurn? = nil, lines: [SessionLine] = [],
        autoFix: (AutoFixSession, AutoFixState)? = nil, cacheTooltip: String? = nil
    ) {
        self.session = session
        self.lines = lines
        let color: NSColor
        switch session.status {
        case .busy: color = Palette.blue
        case .idle: color = Palette.mint
        case .unknown: color = Palette.secondary
        }
        dot.layer?.backgroundColor = color.cgColor
        nameLabel.stringValue = session.name
        cwdLabel.stringValue = session.abbreviatedCwd()
        let rate = burn.map { $0.short == "idle" ? "" : " · \($0.short)" } ?? ""
        ageLabel.stringValue = "\(session.status.rawValue) · \(Format.age(since: session.startedAt, now: now))\(rate)"
        ageLabel.textColor = session.status == .busy ? Palette.blue : Palette.secondary

        if let autoFix {
            let (fix, state) = autoFix
            let stateColor = Palette.autoFix(state)
            marker.stringValue = AutoFix.marker(fix.pr)
            marker.textColor = stateColor
            marker.backgroundColor = stateColor.withAlphaComponent(Palette.increaseContrast ? 0.32 : 0.15)
            marker.layer?.borderWidth = Palette.increaseContrast ? 1 : 0
            marker.layer?.borderColor = stateColor.cgColor
            marker.toolTip = "Auto-fix: the desktop app wakes this session on CI failures, merge conflicts and review comments. State: \(state.label)"
            marker.isHidden = false
            if case .closed = state {
                alphaValue = Palette.increaseContrast ? 0.75 : 0.55
            } else {
                alphaValue = 1
            }
        } else {
            marker.isHidden = true
            alphaValue = 1
        }

        while lineLabels.count < lines.count {
            let label = NSTextField(labelWithString: "")
            label.maximumNumberOfLines = 2
            label.cell?.wraps = true
            label.cell?.truncatesLastVisibleLine = true
            addSubview(label)
            lineLabels.append(label)
        }
        while lineLabels.count > lines.count {
            lineLabels.removeLast().removeFromSuperview()
        }
        for (label, line) in zip(lineLabels, lines) {
            label.attributedStringValue = line.attributed(ClaudeSectionModel.detailFont)
            label.toolTip = line.plain
        }

        toolTip = "pid \(session.pid) · \(session.cwd)\nsession \(session.sessionId)"
            + (session.version.map { "\nClaude Code \($0)" } ?? "")
            + (burn.map { "\n\($0.long)" } ?? "")
            + (cacheTooltip.map { "\n\($0)" } ?? "")
            + "\nClick to copy these lines"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let top = bounds.height - ClaudeSectionModel.sessionRowHeight
        let ageWidth = min(
            ceil((ageLabel.stringValue as NSString).size(withAttributes: [.font: ageLabel.font as Any]).width) + 4,
            160
        )
        let nameWidth = min(
            ceil((nameLabel.stringValue as NSString).size(
                withAttributes: [.font: nameLabel.font as Any]
            ).width) + 4,
            marker.isHidden ? 140 : 110
        )
        dot.frame = NSRect(x: 0, y: top + 7.5, width: 7, height: 7)
        nameLabel.frame = NSRect(x: 13, y: top + 3, width: nameWidth, height: 16)
        var cwdX = 13 + nameWidth + 8
        if !marker.isHidden {
            let markerWidth = ceil((marker.stringValue as NSString).size(withAttributes: [.font: marker.font as Any]).width) + 14
            marker.frame = NSRect(x: cwdX - 2, y: top + 4, width: markerWidth, height: 14)
            cwdX += markerWidth + 6
        }
        cwdLabel.frame = NSRect(
            x: cwdX,
            y: top + 3.5,
            width: max(0, width - cwdX - ageWidth - 8),
            height: 15
        )
        ageLabel.frame = NSRect(x: width - ageWidth, y: top + 3.5, width: ageWidth, height: 15)
        var y = top
        for (label, line) in zip(lineLabels, lines) {
            let height = CGFloat(line.rows) * ClaudeSectionModel.detailLineHeight
            y -= height
            let x: CGFloat = 13 + line.indent
            label.frame = NSRect(x: x, y: y + 1, width: max(0, width - x), height: height)
        }
    }
}

/// Small clickable caption ("COPY ALL") that flashes on click.
@MainActor
final class FlashLabel: NSView {
    private let label: NSTextField
    var onClick: (@MainActor () -> Void)?

    init(text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        label.font = NSFont.systemFont(ofSize: 9.5, weight: .bold)
        label.textColor = Palette.secondary
        label.alignment = .center
        label.drawsBackground = true
        label.backgroundColor = Palette.track
        label.wantsLayer = true
        label.layer?.cornerRadius = 9
        label.layer?.masksToBounds = true
        addSubview(label)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()
        label.frame = bounds
    }

    @objc private func clicked() {
        onClick?()
        flash(self)
    }
}

/// 150 ms background pulse as the only copy confirmation: no alert, no sound.
@MainActor
func flash(_ view: NSView) {
    view.wantsLayer = true
    let highlight = Palette.primary.withAlphaComponent(0.22).cgColor
    let pulse = CABasicAnimation(keyPath: "backgroundColor")
    pulse.fromValue = highlight
    pulse.toValue = NSColor.clear.cgColor
    pulse.duration = 0.15
    view.layer?.add(pulse, forKey: "flash")
}

enum Clipboard {
    /// Replaces the pasteboard contents. Goes through the general pasteboard
    /// on purpose so clipboard managers such as Maccy record it.
    @MainActor
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// PNG of the section on the menu's dark material, for `vitals sessions-preview`.
@MainActor
enum SessionsPreview {
    static func write(_ model: ClaudeSectionModel, to url: URL) throws {
        let view = ClaudeSectionView(model: model)
        let pad: CGFloat = 10
        let bounds = NSRect(x: 0, y: 0, width: view.frame.width + pad * 2, height: view.frame.height + pad * 2)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let container = NSView(frame: bounds)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1).cgColor
        view.frame.origin = NSPoint(x: pad, y: pad)
        container.addSubview(view)
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        container.display()
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { throw CocoaError(.fileWriteUnknown) }
        container.cacheDisplay(in: container.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }

    /// Warm, about to expire, cold, and an auto-fix PR whose CI fails.
    static func samples(now: Date, telemetry: ClaudeTelemetrySnapshot) -> ClaudeSectionModel {
        func session(_ pid: Int32, _ name: String, _ cwd: String, _ status: ClaudeSession.Status, hours: Double) -> ClaudeSession {
            ClaudeSession(pid: pid, sessionId: "sample-\(pid)", name: name, status: status, cwd: cwd,
                          startedAt: now.addingTimeInterval(-hours * 3_600), updatedAt: now, version: "2.1.292")
        }
        func cache(ttl: TimeInterval, ago: TimeInterval, requests: Int, misses: Int = 0, repaid: Int = 0,
                   cause: PromptCache.MissCause? = nil, hit: Double, prompt: Int) -> PromptCache {
            PromptCache(ttl: ttl, lastRequestAt: now.addingTimeInterval(-ago), requests: requests, misses: misses,
                        missRecacheTokens: repaid, lastMissAt: misses > 0 ? now.addingTimeInterval(-ago - 900) : nil,
                        lastMissCause: cause, hitRatio: hit, recacheTokens: prompt, version: "2.1.292")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let warm = session(41_001, "vitals sessions view", home + "/Developer/vitals", .busy, hours: 1)
        let expiring = session(41_002, "Rewrite IHaz* names", home + "/RiderProjects/Fallout", .idle, hours: 5)
        let cold = session(41_003, "Advisor fable", home + "/RiderProjects/Fallout", .idle, hours: 16)
        let failing = session(41_004, "Migrate paths and SDK pin", home + "/RiderProjects/Fallout", .idle, hours: 16)
        let coldCache = cache(ttl: 3_600, ago: 3 * 3_600, requests: 212, misses: 2, repaid: 1_300_000, cause: .expired, hit: 0.94, prompt: 912_000)
        let pr = BoundPullRequest(number: 700, repo: "Fallout-build/Fallout", branch: "bugfix/migrate-paths-and-sdk-pin", baseRef: "develop")
        return ClaudeSectionModel(
            telemetry: telemetry,
            sessions: ClaudeSessionsSnapshot(sessions: [warm, expiring, cold, failing], capturedAt: now),
            now: now,
            caches: [
                warm.pid: SessionCache(
                    main: cache(ttl: 3_600, ago: 22 * 60, requests: 48, hit: 0.91, prompt: 240_000),
                    subagents: [SubagentCache(id: "a1", label: "Explore desktop store",
                                              cache: cache(ttl: 300, ago: 170, requests: 12, hit: 0.84, prompt: 61_000))]
                ),
                expiring.pid: SessionCache(
                    main: cache(ttl: 3_600, ago: 52 * 60, requests: 30, misses: 1, repaid: 140_000, hit: 0.88, prompt: 180_000),
                    subagents: [SubagentCache(id: "a2", label: "Run Fallout test target",
                                              cache: cache(ttl: 300, ago: 280, requests: 9, misses: 2, repaid: 180_000, cause: .expired, hit: 0.41, prompt: 92_000))]
                ),
                cold.pid: SessionCache(main: coldCache, hint: PromptCacheText.hint(coldCache, runningVersion: "2.1.292", instructionsEdited: false, now: now)),
                failing.pid: SessionCache(main: cache(ttl: 3_600, ago: 6 * 60, requests: 21, hit: 0.9, prompt: 150_000))
            ],
            autoFix: [
                failing.pid: AutoFixSession(
                    pid: failing.pid, localId: "local_sample", cliSessionId: failing.sessionId, pr: pr,
                    activity: AutoFixActivity(kinds: ["CI failure"], at: now.addingTimeInterval(-9 * 60), pushed: "da8f1b6"),
                    status: PullRequestStatus(state: "OPEN", ci: .failing, failingChecks: ["build / ubuntu-latest"],
                                              reviewDecision: "REVIEW_REQUIRED", mergeable: "MERGEABLE", fetchedAt: now)
                )
            ],
            processes: [failing.pid: ProcessUsage(cpuPercent: 0.3, footprintBytes: 274_726_912)]
        )
    }
}
