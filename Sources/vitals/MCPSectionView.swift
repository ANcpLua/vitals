import AppKit
import VitalsMCP

/// Header of the MCP block: count badge and Copy all.
@MainActor
final class MCPHeaderView: NSView {
    private let sectionLabel = NSTextField(labelWithString: "MCP SERVERS")
    private let detailLabel = NSTextField(labelWithString: "")
    private let copyAllLabel = FlashLabel(text: "COPY ALL")

    init(width: CGFloat, onCopyAll: @escaping @MainActor () -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        sectionLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        sectionLabel.textColor = Palette.secondary
        detailLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        detailLabel.textColor = Palette.secondary
        detailLabel.alignment = .right
        copyAllLabel.toolTip = "Copy every server with its callable tool names, one line each"
        copyAllLabel.onClick = onCopyAll
        addSubview(sectionLabel)
        addSubview(detailLabel)
        addSubview(copyAllLabel)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func update(servers: Int, tools: Int, probing: Bool) {
        var text = "\(servers) server\(servers == 1 ? "" : "s") · \(tools) tool\(tools == 1 ? "" : "s")"
        if probing { text = "probing… · " + text }
        detailLabel.stringValue = text
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = 16.0
        let copyWidth = 66.0
        sectionLabel.frame = NSRect(x: inset, y: 6, width: 100, height: 14)
        detailLabel.frame = NSRect(x: inset + 100, y: 6, width: bounds.width - inset * 2 - 100 - copyWidth - 8, height: 14)
        copyAllLabel.frame = NSRect(x: bounds.width - inset - copyWidth, y: 4, width: copyWidth, height: 18)
    }
}

/// One server row: status dot, name, scope tag, tool count. Click copies
/// the server's line; the submenu holds the tools and the per-project toggles.
@MainActor
final class MCPRowView: NSView {
    static let height = 22.0

    private let dot = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let scopeLabel = NSTextField(labelWithString: "")
    private let toolsLabel = NSTextField(labelWithString: "")
    private var onCopy: (@MainActor () -> Void)?

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        wantsLayer = true
        layer?.cornerRadius = 5
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        nameLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        nameLabel.textColor = Palette.primary
        nameLabel.lineBreakMode = .byTruncatingMiddle
        scopeLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .bold)
        scopeLabel.textColor = Palette.secondary
        scopeLabel.alignment = .center
        scopeLabel.drawsBackground = true
        scopeLabel.backgroundColor = Palette.track
        scopeLabel.wantsLayer = true
        scopeLabel.layer?.cornerRadius = 7
        scopeLabel.layer?.masksToBounds = true
        toolsLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        toolsLabel.textColor = Palette.secondary
        toolsLabel.alignment = .right
        addSubview(dot)
        addSubview(nameLabel)
        addSubview(scopeLabel)
        addSubview(toolsLabel)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func update(_ server: MCPServer, record: MCPProbeRecord?, probing: Bool, onCopy: @escaping @MainActor () -> Void) {
        self.onCopy = onCopy
        let color: NSColor
        if server.isEnabledEverywhere { color = Palette.mint }
        else if server.isEnabledAnywhere { color = Palette.amber }
        else if server.status.values.contains(.pendingApproval) { color = Palette.blue }
        else { color = Palette.secondary }
        dot.layer?.backgroundColor = color.cgColor
        nameLabel.stringValue = server.name
        nameLabel.textColor = server.isEnabledAnywhere ? Palette.primary : Palette.secondary
        scopeLabel.stringValue = server.scope.label.uppercased()
        if probing {
            toolsLabel.stringValue = "probing…"
            toolsLabel.textColor = Palette.blue
        } else if let record {
            if let error = record.error {
                toolsLabel.stringValue = "failed"
                toolsLabel.textColor = Palette.coral
                toolsLabel.toolTip = error
            } else {
                toolsLabel.stringValue = "\(record.tools.count) tools · \(Format.age(since: record.probedAt))"
                toolsLabel.textColor = Palette.secondary
            }
        } else {
            toolsLabel.stringValue = server.transport.isProbeable ? "not probed" : server.transport.summary
            toolsLabel.textColor = Palette.secondary
        }
        toolTip = "\(MCPText.statusSummary(server)) · \(server.transport.summary)\nClick to copy this server's line"
        needsLayout = true
    }

    @objc private func clicked() {
        onCopy?()
        flash(self)
    }

    override func layout() {
        super.layout()
        let inset = 16.0
        let width = bounds.width
        let scopeWidth = 58.0
        let toolsWidth = 118.0
        dot.frame = NSRect(x: inset, y: 7.5, width: 7, height: 7)
        let nameX = inset + 13
        let toolsX = width - inset - toolsWidth
        let scopeX = toolsX - 8 - scopeWidth
        nameLabel.frame = NSRect(x: nameX, y: 3, width: max(0, scopeX - nameX - 8), height: 16)
        scopeLabel.frame = NSRect(x: scopeX, y: 4, width: scopeWidth, height: 14)
        toolsLabel.frame = NSRect(x: toolsX, y: 3.5, width: toolsWidth, height: 15)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard enclosingMenuItem?.isHighlighted == true else { return }
        Palette.primary.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}
