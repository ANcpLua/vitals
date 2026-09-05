import AppKit
import VitalsCore

/// Floating, non-activating search panel over the clipboard history. Typing
/// lands in the search field without bringing Vitals to the front, so the
/// app you paste into keeps focus. Return or a click copies the entry and
/// closes the panel; Escape or clicking elsewhere closes it.
@MainActor
final class ClipboardPanel: NSPanel, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let monitor: ClipboardMonitor
    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let countLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "↩ copies · esc closes · ⌃⇧V toggles")
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private var rows: [ClipboardEntry] = []
    private static let column = NSUserInterfaceItemIdentifier("entry")

    init(monitor: ClipboardMonitor) {
        self.monitor = monitor
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        minSize = NSSize(width: 360, height: 220)

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        contentView = effect
        build(in: effect)
        monitor.onChange = { [weak self] in
            guard let self, self.isVisible else { return }
            self.reload(keepingSelection: true)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func toggle() {
        if isVisible {
            orderOut(nil)
            return
        }
        searchField.stringValue = ""
        reload(keepingSelection: false)
        place()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(searchField)
    }

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }

    // MARK: Layout

    private func build(in container: NSView) {
        searchField.placeholderString = "Search clipboard"
        searchField.font = NSFont.systemFont(ofSize: 14)
        searchField.delegate = self
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = true

        let column = NSTableColumn(identifier: Self.column)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 30
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.selectionHighlightStyle = .regular
        table.style = .fullWidth
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.refusesFirstResponder = true

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = Palette.secondary
        hintLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        hintLabel.textColor = Palette.secondary
        hintLabel.alignment = .right
        clearButton.target = self
        clearButton.action = #selector(clearHistory)
        clearButton.bezelStyle = .accessoryBarAction
        clearButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)

        for view in [searchField, scroll, countLabel, hintLabel, clearButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: clearButton.topAnchor, constant: -6),
            clearButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            clearButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            countLabel.centerYAnchor.constraint(equalTo: clearButton.centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            hintLabel.centerYAnchor.constraint(equalTo: clearButton.centerYAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -12)
        ])
    }

    /// Centered, slightly above the middle, on the screen under the mouse.
    private func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = frame.size
        setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.08
        ))
    }

    // MARK: Data

    private func reload(keepingSelection: Bool) {
        let selected = keepingSelection && table.selectedRow >= 0 && table.selectedRow < rows.count
            ? rows[table.selectedRow] : nil
        rows = monitor.history.filtered(searchField.stringValue)
        table.reloadData()
        let total = monitor.history.entries.count
        countLabel.stringValue = searchField.stringValue.isEmpty
            ? "\(total) \(total == 1 ? "entry" : "entries")"
            : "\(rows.count) of \(total)"
        if let selected, let index = rows.firstIndex(of: selected) {
            select(index)
        } else if !rows.isEmpty {
            select(0)
        }
    }

    private func select(_ row: Int) {
        guard row >= 0, row < rows.count else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func choose(_ row: Int) {
        guard row >= 0, row < rows.count else { return }
        monitor.copy(rows[row])
        orderOut(nil)
    }

    @objc private func rowClicked() {
        choose(table.clickedRow)
    }

    @objc private func clearHistory() {
        monitor.clear()
        reload(keepingSelection: false)
    }

    // MARK: NSSearchFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        reload(keepingSelection: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            select(min(table.selectedRow + 1, rows.count - 1))
        case #selector(NSResponder.moveUp(_:)):
            select(max(table.selectedRow - 1, 0))
        case #selector(NSResponder.insertNewline(_:)):
            choose(table.selectedRow >= 0 ? table.selectedRow : 0)
        case #selector(NSResponder.cancelOperation(_:)):
            orderOut(nil)
        default:
            return false
        }
        return true
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = tableView.makeView(withIdentifier: Self.column, owner: nil) as? ClipboardRowView
            ?? ClipboardRowView(identifier: Self.column)
        view.update(rows[row])
        return view
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = ClipboardTableRowView()
        return view
    }
}

private final class ClipboardTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        Palette.blue.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 0), xRadius: 6, yRadius: 6).fill()
    }
}

private final class ClipboardRowView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.textColor = Palette.primary
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        metaLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        metaLabel.textColor = Palette.secondary
        metaLabel.alignment = .right
        addSubview(titleLabel)
        addSubview(metaLabel)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func update(_ entry: ClipboardEntry) {
        titleLabel.stringValue = entry.title
        let lines = entry.lineCount
        metaLabel.stringValue = (lines > 1 ? "\(lines) lines · " : "") + Format.age(since: entry.capturedAt)
        toolTip = entry.text.count > 400 ? String(entry.text.prefix(400)) + "…" : entry.text
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let metaWidth: CGFloat = 96
        metaLabel.frame = NSRect(x: bounds.width - 12 - metaWidth, y: 7, width: metaWidth, height: 14)
        titleLabel.frame = NSRect(x: 12, y: 6, width: max(0, bounds.width - 12 - metaWidth - 20), height: 17)
    }
}
