import AppKit
import VitalsCore

/// Stacked area sparkline for a 60 s CPU window. Values are in cores
/// (1.0 = 100%). Everything above one core is drawn again as a further
/// layer on top, so a four-core peak fits a 12 pt row without a y-axis:
/// the height shows the fraction of the current core, the layer count and
/// colour show how many cores are in use.
@MainActor
final class SparklineView: NSView {
    private var values: [Double?] = []

    private static let maxLayers = 4
    private static let layerColors: [NSColor] = [
        Palette.blue.withAlphaComponent(0.75),
        Palette.amber.withAlphaComponent(0.8),
        Palette.amber.withAlphaComponent(0.95),
        Palette.coral
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 2
        layer?.masksToBounds = true
        layer?.backgroundColor = Palette.track.cgColor
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func update(_ values: [Double?]) {
        guard values != self.values else { return }
        self.values = values
        needsDisplay = true
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard values.count > 1 else { return }
        let peak = values.compactMap { $0 }.max() ?? 0
        let layers = min(Self.maxLayers, max(1, Int(peak.rounded(.up))))
        for layer in 0..<layers {
            let path = Self.area(
                values.map { max(0, min(1, ($0 ?? 0) - Double(layer))) },
                in: bounds
            )
            Self.layerColors[layer].setFill()
            path.fill()
        }
    }

    private static func area(_ fractions: [Double], in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        let step = rect.width / CGFloat(fractions.count - 1)
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        for (index, fraction) in fractions.enumerated() {
            path.line(to: NSPoint(
                x: rect.minX + CGFloat(index) * step,
                y: rect.minY + CGFloat(fraction) * rect.height
            ))
        }
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.close()
        return path
    }
}

/// One top-level process row: CPU, memory, name, 60 s sparkline. Replaces the
/// attributed-title menu item so the graph can live inside the row. Draws its
/// own highlight because AppKit does not highlight custom item views.
@MainActor
final class ProcessRowView: NSView {
    static let height = 22.0
    static let sparklineWidth = 84.0
    static let networkWidth = 96.0

    private let cpuLabel = NSTextField(labelWithString: "")
    private let memLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let netLabel = NSTextField(labelWithString: "")
    private let sparkline = SparklineView()
    private let showsNetwork: Bool
    /// Last known window peak, so an exited row keeps showing "^16%" after
    /// its ring has been dropped from the history.
    private var lastPeak: Double?

    init(showsNetwork: Bool) {
        self.showsNetwork = showsNetwork
        super.init(frame: NSRect(x: 0, y: 0, width: 352, height: Self.height))
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        cpuLabel.font = mono
        cpuLabel.alignment = .right
        memLabel.font = mono
        memLabel.alignment = .right
        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        netLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        netLabel.alignment = .right
        netLabel.isHidden = !showsNetwork
        addSubview(cpuLabel)
        addSubview(memLabel)
        addSubview(nameLabel)
        addSubview(netLabel)
        addSubview(sparkline)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func update(cpu: Double?, mem: UInt64?, name: String, exited: Bool, peak: Double?, series: [Double?], net: NetworkRate?) {
        let peak = peak ?? lastPeak
        lastPeak = peak
        netLabel.stringValue = net.map { "↓\(compactRate($0.inPerSecond)) ↑\(compactRate($0.outPerSecond))" } ?? "--"
        netLabel.textColor = net.map { $0.total > 0 ? Palette.primary : Palette.secondary } ?? Palette.secondary
        cpuLabel.stringValue = cpu.map { String(format: "%.0f%%", $0) }
            ?? peak.map { String(format: "^%.0f%%", $0) }
            ?? "--"
        cpuLabel.textColor = cpu.map(Palette.processCPU) ?? Palette.secondary
        memLabel.stringValue = mem.map(compactBytes) ?? "--"
        memLabel.textColor = mem == nil ? Palette.secondary : Palette.mint
        nameLabel.stringValue = name
        let nameFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        nameLabel.font = exited
            ? NSFontManager.shared.convert(nameFont, toHaveTrait: .italicFontMask)
            : nameFont
        nameLabel.textColor = exited ? Palette.coral.withAlphaComponent(0.7) : Palette.primary
        sparkline.update(series)
        toolTip = "60 s window · peak \(String(format: "%.0f%%", peak ?? 0))"
    }

    override func layout() {
        super.layout()
        let sparkX = bounds.width - 16 - Self.sparklineWidth
        let netX = sparkX - 8 - Self.networkWidth
        let nameEnd = showsNetwork ? netX : sparkX
        cpuLabel.frame = NSRect(x: 16, y: 3, width: 36, height: 16)
        memLabel.frame = NSRect(x: 60, y: 3, width: 52, height: 16)
        nameLabel.frame = NSRect(x: 124, y: 3, width: max(0, nameEnd - 124 - 10), height: 16)
        netLabel.frame = NSRect(x: netX, y: 3.5, width: Self.networkWidth, height: 15)
        sparkline.frame = NSRect(x: sparkX, y: 5, width: Self.sparklineWidth, height: 12)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard enclosingMenuItem?.isHighlighted == true else { return }
        Palette.primary.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

/// "0", "820", "12K", "1.3M", "2.1G" per second, sized for a 96 pt column.
func compactRate(_ bytesPerSecond: Double) -> String {
    let value = max(0, bytesPerSecond)
    if value >= 1_000_000_000 { return String(format: "%.1fG", value / 1_000_000_000) }
    if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
    if value >= 1_000 { return String(format: "%.0fK", value / 1_000) }
    return String(format: "%.0f", value)
}

func compactBytes(_ bytes: UInt64) -> String {
    let gib = Double(bytes) / 1_073_741_824.0
    if gib >= 10 { return String(format: "%.1fG", gib) }
    if gib >= 1 { return String(format: "%.2fG", gib) }
    return String(format: "%.0fM", Double(bytes) / 1_048_576.0)
}
