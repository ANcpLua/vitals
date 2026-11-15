import AppKit
import VitalsCore
import VitalsKernel

/// Floating panel for placing a hotspot or modem. Nothing is sent while it is
/// closed: opening it starts the echo and the upload, Stop and Start pause and
/// resume, and closing it (esc, the close button, clicking elsewhere) stops and
/// releases everything: probe threads and sockets, the tone engine, the timer. The whole
/// panel turns green, amber or red four times a second, and a tone rises with
/// the quality so the device can be moved without looking at the screen.
@MainActor
final class PlacementPanel: NSPanel {
    private let background = NSView()
    private let wordLabel = NSTextField(labelWithString: "OFF")
    private let rateLabel = NSTextField(labelWithString: "- Mbit/s")
    private let infoLabel = NSTextField(labelWithString: "")
    private let trend = PlacementTrendView()
    private let startButton = NSButton(title: "Start", target: nil, action: nil)
    private let limitPopup = NSPopUpButton()
    private let volumeSlider = NSSlider(value: 0.4, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let toneLabel = NSTextField(labelWithString: "Tone")
    private let footerLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "space starts and stops · esc closes")

    private var probe: PlacementProbe?
    private let tone = PlacementTone()
    private var loop: Task<Void, Never>?
    private var uploadWindow = UploadWindow(seconds: 1)
    private var recent: [Double?] = []
    private var best = 0.0
    private var lostInSecond: [Bool] = []
    private var stopAt: Date?
    private var openedAt = Date()

    private static let volumeKey = "placementVolume"
    private static let limitKey = "placementLimit"
    private static let trendSeconds = 30

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "Placement"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        background.wantsLayer = true
        contentView = background
        build()
        apply(nil, uploading: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func toggle() {
        if isVisible {
            close()
            return
        }
        open()
    }

    private func open() {
        openedAt = Date()
        best = 0
        recent = []
        lostInSecond = []
        uploadWindow.reset()
        // Opening is the explicit action: the upload starts with the panel and
        // ends with it. Stop and Start in between only pause it.
        let probe = PlacementProbe()
        probe.setLimit(mbit: currentLimit)
        probe.start()
        probe.setUploading(true)
        stopAt = Date().addingTimeInterval(Placement.autoStopSeconds)
        self.probe = probe
        place()
        makeKeyAndOrderFront(nil)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1_000 / Placement.hz))
                self?.tick()
            }
        }
    }

    private var closing = false

    override func close() {
        guard !closing else { return }
        closing = true
        defer { closing = false }
        loop?.cancel()
        loop = nil
        probe?.stop()
        probe = nil
        stopAt = nil
        tone.stop()
        apply(nil, uploading: false)
        super.close()
    }

    override func resignKey() {
        super.resignKey()
        if isVisible { close() }
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            toggleUpload()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Measuring

    private var currentLimit: Double {
        let saved = UserDefaults.standard.double(forKey: Self.limitKey)
        return Placement.limits.contains(saved) ? saved : Placement.defaultLimit
    }

    @objc private func toggleUpload() {
        guard let probe else { return }
        let on = stopAt == nil
        stopAt = on ? Date().addingTimeInterval(Placement.autoStopSeconds) : nil
        probe.setUploading(on)
        if !on { tone.silence() }
    }

    @objc private func limitChanged() {
        let limit = Placement.limits[max(0, limitPopup.indexOfSelectedItem)]
        UserDefaults.standard.set(limit, forKey: Self.limitKey)
        probe?.setLimit(mbit: limit)
        best = 0
    }

    @objc private func volumeChanged() {
        UserDefaults.standard.set(volumeSlider.doubleValue, forKey: Self.volumeKey)
    }

    private func tick() {
        guard let probe else { return }
        if let stopAt, Date() >= stopAt {
            self.stopAt = nil
            probe.setUploading(false)
            tone.silence()
        }
        let reading = probe.read()
        let mbit = uploadWindow.adding(time: Date.timeIntervalSinceReferenceDate, bytes: reading.ackedBytes)
        recent.append(reading.uploading ? mbit : nil)
        if recent.count > Self.trendSeconds * Placement.hz { recent.removeFirst() }
        lostInSecond.append(reading.lostPing)
        if lostInSecond.count > Placement.hz { lostInSecond.removeFirst() }
        best = Placement.best(previous: best, recent: recent)

        // Judge only once a full second of upload is in the window.
        let lastSecond = recent.suffix(Placement.hz)
        var verdict: PlacementVerdict?
        if reading.uploading, lastSecond.count == Placement.hz, lastSecond.allSatisfy({ $0 != nil }) {
            let reference = Placement.reference(best: best, limitMbit: currentLimit)
            verdict = Placement.decide(uploadMbit: mbit, lostPing: lostInSecond.contains(true), reference: reference)
        }
        apply(verdict, uploading: reading.uploading, mbit: mbit, reading: reading)
        if let verdict, verdict.grade != .dropout {
            tone.set(frequency: Placement.toneHz(quality: verdict.quality), volume: volumeSlider.doubleValue)
        } else if verdict?.grade == .dropout {
            tone.set(frequency: 160, volume: volumeSlider.doubleValue)
        } else {
            tone.silence()
        }
    }

    // MARK: Preview

    /// Renders the panel in the given state to PNG without measuring anything.
    func writePreview(_ verdict: PlacementVerdict?, mbit: Double, best: Double, values: [Double?], to url: URL) throws {
        self.best = best
        recent = values
        stopAt = verdict == nil ? nil : Date().addingTimeInterval(Placement.autoStopSeconds)
        apply(verdict, uploading: verdict != nil, mbit: mbit, reading: nil)
        let view = background
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }

    // MARK: Display

    private func apply(_ verdict: PlacementVerdict?, uploading: Bool, mbit: Double = 0, reading: PlacementProbe.Reading? = nil) {
        let fill: NSColor
        let ink: NSColor
        switch verdict?.grade {
        case .good?: (fill, ink) = (Palette.mint, .black)
        case .fair?: (fill, ink) = (Palette.amber, .black)
        case .poor?, .dropout?: (fill, ink) = (Palette.coral, .black)
        case nil: (fill, ink) = (NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1), Palette.primary)
        }
        background.layer?.backgroundColor = fill.cgColor
        let soft = ink.withAlphaComponent(0.7)
        for label in [wordLabel, rateLabel] { label.textColor = ink }
        for label in [infoLabel, footerLabel, hintLabel, toneLabel] { label.textColor = soft }
        trend.ink = ink

        switch verdict?.grade {
        case .good?: wordLabel.stringValue = "GOOD"
        case .fair?: wordLabel.stringValue = "FAIR"
        case .poor?: wordLabel.stringValue = "POOR"
        case .dropout?: wordLabel.stringValue = "DROPOUT"
        case nil: wordLabel.stringValue = uploading ? "..." : "OFF"
        }
        rateLabel.stringValue = uploading ? String(format: "%.1f Mbit/s", mbit) : "- Mbit/s"
        let ping = reading?.pingMs.map { String(format: "ping %.0f ms", $0) } ?? "ping lost"
        if !uploading {
            infoLabel.stringValue = "Start, then turn and move the phone or modem slowly. \(reading == nil ? "" : ping)"
        } else {
            let reference = Placement.reference(best: best, limitMbit: currentLimit)
            infoLabel.stringValue = String(format: "best so far %.1f Mbit/s · ", reference) + ping
                + (reading?.error.map { " · \($0)" } ?? "")
        }
        startButton.title = uploading ? "Stop" : "Start"
        startButton.bezelColor = uploading ? nil : Palette.blue
        let used = Double(reading?.ackedBytes ?? 0) / 1_000_000
        var footer = String(format: "%.0f MB uploaded", used)
        if uploading, let stopAt {
            let left = max(0, Int(stopAt.timeIntervalSinceNow))
            footer += String(format: " · about %.0f MB/min · stops by itself in %d:%02d", currentLimit * 7.5, left / 60, left % 60)
        }
        footerLabel.stringValue = footer
        trend.update(values: recent, best: best, capacity: Self.trendSeconds * Placement.hz)
    }

    private func build() {
        wordLabel.font = NSFont.systemFont(ofSize: 64, weight: .heavy)
        wordLabel.alignment = .center
        rateLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 30, weight: .bold)
        rateLabel.alignment = .center
        infoLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        infoLabel.alignment = .center
        infoLabel.lineBreakMode = .byTruncatingTail
        footerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        hintLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        hintLabel.alignment = .center
        footerLabel.alignment = .center
        footerLabel.lineBreakMode = .byTruncatingTail
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toneLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)

        startButton.target = self
        startButton.action = #selector(toggleUpload)
        startButton.bezelStyle = .rounded
        startButton.controlSize = .large
        startButton.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        startButton.keyEquivalent = ""

        limitPopup.addItems(withTitles: Placement.limits.map { "limit \(Int($0)) Mbit/s" })
        limitPopup.selectItem(at: Placement.limits.firstIndex(of: currentLimit) ?? 1)
        limitPopup.target = self
        limitPopup.action = #selector(limitChanged)
        limitPopup.controlSize = .regular

        if UserDefaults.standard.object(forKey: Self.volumeKey) != nil {
            volumeSlider.doubleValue = UserDefaults.standard.double(forKey: Self.volumeKey)
        }
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        volumeSlider.isContinuous = true

        let controls = NSStackView(views: [startButton, limitPopup, toneLabel, volumeSlider])
        controls.orientation = .horizontal
        controls.spacing = 10
        controls.alignment = .centerY

        for view in [wordLabel, rateLabel, infoLabel, trend, controls, footerLabel, hintLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        let side: CGFloat = 18
        NSLayoutConstraint.activate([
            wordLabel.topAnchor.constraint(equalTo: background.topAnchor, constant: 34),
            wordLabel.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            rateLabel.topAnchor.constraint(equalTo: wordLabel.bottomAnchor, constant: 2),
            rateLabel.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            infoLabel.topAnchor.constraint(equalTo: rateLabel.bottomAnchor, constant: 6),
            infoLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: side),
            infoLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -side),
            trend.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 12),
            trend.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: side),
            trend.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -side),
            trend.heightAnchor.constraint(equalToConstant: 56),
            controls.topAnchor.constraint(equalTo: trend.bottomAnchor, constant: 14),
            controls.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            volumeSlider.widthAnchor.constraint(equalToConstant: 110),
            hintLabel.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 10),
            hintLabel.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            footerLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: side),
            footerLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -side),
            footerLabel.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12)
        ])
    }

    private func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = frame.size
        setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
    }
}

/// Upload over the last 30 s with the best value as a dashed line.
@MainActor
final class PlacementTrendView: NSView {
    private var values: [Double?] = []
    private var best = 0.0
    private var capacity = 120
    var ink: NSColor = Palette.primary {
        didSet { needsDisplay = true }
    }

    func update(values: [Double?], best: Double, capacity: Int) {
        self.values = values
        self.best = best
        self.capacity = capacity
        needsDisplay = true
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let top = max(1, values.compactMap { $0 }.max() ?? 0, best) * 1.1
        let width = bounds.width
        let height = bounds.height
        let step = width / CGFloat(max(1, capacity - 1))
        func x(_ index: Int) -> CGFloat { width - CGFloat(values.count - 1 - index) * step }
        func y(_ value: Double) -> CGFloat { 2 + CGFloat(value / top) * (height - 4) }

        if best > 0 {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 0, y: y(best)))
            line.line(to: NSPoint(x: width, y: y(best)))
            line.setLineDash([4, 4], count: 2, phase: 0)
            line.lineWidth = 1
            ink.withAlphaComponent(0.45).setStroke()
            line.stroke()
        }
        let path = NSBezierPath()
        path.lineWidth = 2.5
        path.lineJoinStyle = .round
        var pen = false
        for (index, value) in values.enumerated() {
            guard let value else {
                pen = false
                continue
            }
            let point = NSPoint(x: x(index), y: y(value))
            if pen { path.line(to: point) } else { path.move(to: point) }
            pen = true
        }
        ink.setStroke()
        path.stroke()
    }
}
