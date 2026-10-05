import AppKit
import ServiceManagement

final class Sparkline: NSView {
    var samples: [MeterSample] = [] { didSet { if frozenSamples == nil { needsDisplay = true } } }
    var live = false { didSet { if live != oldValue { needsDisplay = true } } }
    var onInspect: ((IntervalStatistics?) -> Void)?
    private var frozenSamples: [MeterSample]?
    private var selection: IntervalStatistics?
    private var mouseTracking: NSTrackingArea?
    private var displayedSamples: [MeterSample] { frozenSamples ?? samples }
    private var plot: NSRect { NSRect(x: 2, y: 16, width: bounds.width - 4, height: bounds.height - 21) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTracking = mouseTracking { removeTrackingArea(mouseTracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .enabledDuringMouseDrag, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); mouseTracking = area
        setAccessibilityLabel(L("Speed chart. Hover to inspect a two-second interval."))
    }

    override func mouseEntered(with event: NSEvent) {
        frozenSamples = samples
        inspect(event)
    }

    override func mouseMoved(with event: NSEvent) { inspect(event) }
    override func mouseDown(with event: NSEvent) { inspect(event) }
    override func mouseDragged(with event: NSEvent) { inspect(event) }

    override func mouseExited(with event: NSEvent) {
        clearInspection()
    }

    func clearInspection() {
        frozenSamples = nil; selection = nil
        onInspect?(nil); needsDisplay = true
    }

    private func inspect(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { clearInspection(); return }
        guard let first = displayedSamples.first, let last = displayedSamples.last, plot.width > 0 else { return }
        let fraction = min(1, max(0, (point.x - plot.minX) / plot.width))
        let time = first.time + Double(fraction) * (last.time - first.time)
        showInspection(endingAt: time)
    }

    func showInspection(endingAt time: Double) {
        if frozenSamples == nil { frozenSamples = samples }
        let closest = displayedSamples.filter { $0.speed != nil }.min { abs($0.time - time) < abs($1.time - time) }
        selection = closest.flatMap { intervalStatistics(in: displayedSamples, endingAt: $0.time) }
        onInspect?(selection); needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let samples = displayedSamples
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return }
        let maxValue = max(1, samples.compactMap(\.speed).max() ?? 1)
        func x(_ time: Double) -> CGFloat {
            plot.minX + CGFloat((time - first.time) / (last.time - first.time)) * plot.width
        }
        func point(_ sample: MeterSample) -> NSPoint {
            NSPoint(x: x(sample.time), y: plot.minY + CGFloat((sample.speed ?? 0) / maxValue) * plot.height)
        }
        if let selection = selection {
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            NSRect(x: x(selection.start), y: plot.minY, width: x(selection.end) - x(selection.start), height: plot.height).fill()
        }
        let path = NSBezierPath()
        var previous: MeterSample?
        for sample in samples where sample.speed != nil {
            if previous == nil || sample.time - previous!.time > 1.5 { path.move(to: point(sample)) }
            else { path.line(to: point(sample)) }
            previous = sample
        }
        (live ? NSColor.systemGreen : NSColor.secondaryLabelColor).setStroke()
        path.lineWidth = 1.6; path.stroke()
        if let selection = selection, let sample = samples.last(where: { $0.time <= selection.end && $0.speed != nil }) {
            let p = point(sample)
            NSColor.controlAccentColor.setStroke()
            let cursor = NSBezierPath(); cursor.move(to: NSPoint(x: p.x, y: plot.minY))
            cursor.line(to: NSPoint(x: p.x, y: plot.maxY)); cursor.lineWidth = 1; cursor.stroke()
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor]
        let start = timelineTime(first.time) as NSString, end = timelineTime(last.time) as NSString
        start.draw(at: NSPoint(x: 1, y: 0), withAttributes: attributes)
        end.draw(at: NSPoint(x: bounds.width - end.size(withAttributes: attributes).width - 1, y: 0), withAttributes: attributes)
    }
}

func timelineTime(_ time: Double, includeUnit: Bool = true) -> String {
    if time < 60 { return String(format: "%.1f%@", time, includeUnit ? L(" s") : "") }
    return String(format: "%d:%04.1f", Int(time) / 60, time.truncatingRemainder(dividingBy: 60))
}

func effortName(_ effort: String?) -> String {
    guard let effort = effort, !effort.isEmpty else { return L("Not set") }
    return ["none": "None", "minimal": "Minimal", "low": "Low", "medium": "Medium",
            "high": "High", "xhigh": "XHigh", "max": "Max", "ultra": "Ultra"][effort] ?? effort
}

final class EffortBadge: NSView {
    private let label = NSTextField(labelWithString: L("Effort · —"))
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .secondaryLabelColor; label.alignment = .center
        label.frame = NSRect(x: 5, y: 4, width: frame.width - 10, height: 14)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.055).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
    func update(_ effort: String?) {
        label.stringValue = String(format: L("Effort · %@"), effortName(effort))
        label.toolTip = String(format: L("Selected Codex reasoning effort: %@"), effortName(effort))
    }
}

final class SpeedStatistics: NSView {
    private var values: [NSTextField] = []
    private var labels: [NSTextField] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        let titles = [L("Minimum"), L("Average"), L("Maximum")]
        let explanations = [
            L("Minimum speed in the current segment, tok/s"),
            L("Average speed in the current segment, tok/s"),
            L("Maximum speed in the current segment, tok/s")
        ]
        let width = frame.width / 3
        for i in 0..<3 {
            let label = NSTextField(labelWithString: titles[i])
            label.font = .systemFont(ofSize: 10, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.frame = NSRect(x: CGFloat(i) * width + 4, y: 36, width: width - 8, height: 14)
            let value = NSTextField(labelWithString: "—")
            value.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
            value.alignment = .center
            value.frame = NSRect(x: CGFloat(i) * width + 4, y: 11, width: width - 8, height: 24)
            label.toolTip = explanations[i]; value.toolTip = explanations[i]
            values.append(value)
            labels.append(label)
            addSubview(label); addSubview(value)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.045).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        let separators = NSBezierPath()
        for i in 1...2 {
            let x = bounds.width / 3 * CGFloat(i)
            separators.move(to: NSPoint(x: x, y: 12))
            separators.line(to: NSPoint(x: x, y: bounds.height - 12))
        }
        separators.lineWidth = 0.5; separators.stroke()
    }

    func update(_ reading: MeterReading?, interval: IntervalStatistics? = nil) {
        let numbers: [Double?] = interval.map { [$0.minimum, $0.average, $0.maximum] }
            ?? [reading?.minimum, reading?.average, reading?.maximum]
        for (i, number) in numbers.enumerated() {
            let text = number.map { String(format: "≈ %.1f", $0) } ?? "—"
            values[i].stringValue = text
            values[i].font = .monospacedDigitSystemFont(ofSize: text.count > 8 ? 14 : 18, weight: .semibold)
            values[i].textColor = i == 2 && interval != nil ? .controlAccentColor
                : (i == 2 && reading?.streaming == true ? .systemGreen : .labelColor)
            let tips = interval == nil
                ? [L("Minimum speed in the current segment, tok/s"), L("Average speed in the current segment, tok/s"), L("Maximum speed in the current segment, tok/s")]
                : [L("Minimum speed in the selected interval, tok/s"), L("Average speed in the selected interval, tok/s"), L("Maximum speed in the selected interval, tok/s")]
            let tip = tips[i]
            values[i].toolTip = tip; labels[i].toolTip = tip
        }
    }
}

final class MeterCard: NSView {
    private let title = NSTextField(labelWithString: "Tokenometr")
    private let status = NSTextField(labelWithString: L("Waiting for Codex"))
    private let speed = NSTextField(labelWithString: "—")
    private let subtitle = NSTextField(labelWithString: L("tokens / second"))
    private let model = NSTextField(labelWithString: "Codex")
    private let details = NSTextField(labelWithString: "")
    private let thread = NSTextField(labelWithString: "")
    private let chart = Sparkline()
    private let scope = NSTextField(labelWithString: L("Response stats · hover to inspect"))
    private let statistics = SpeedStatistics(frame: NSRect(x: 18, y: 100, width: 306, height: 56))
    private let effort = EffortBadge(frame: NSRect(x: 198, y: 70, width: 126, height: 22))
    private var graphFragmentID: String?
    private var lastState = MonitorState()
    private var inspectedInterval: IntervalStatistics?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 342, height: 382))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 18, y: 354, width: 306, height: 18)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 18, y: 332, width: 306, height: 17)
        speed.font = .monospacedDigitSystemFont(ofSize: 42, weight: .medium)
        speed.frame = NSRect(x: 16, y: 272, width: 310, height: 53)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 18, y: 253, width: 306, height: 18)
        chart.frame = NSRect(x: 18, y: 187, width: 306, height: 54)
        scope.font = .systemFont(ofSize: 10, weight: .medium)
        scope.textColor = .secondaryLabelColor
        scope.frame = NSRect(x: 18, y: 164, width: 306, height: 16)
        scope.toolTip = L("Hover to inspect about two seconds of text arrivals. Time starts with the first observed chunk.")
        chart.onInspect = { [weak self] interval in
            self?.inspectedInterval = interval
            self?.updateStatistics()
        }
        model.font = .systemFont(ofSize: 12, weight: .medium)
        model.frame = NSRect(x: 18, y: 73, width: 173, height: 18)
        model.lineBreakMode = .byTruncatingTail
        details.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        details.textColor = .secondaryLabelColor
        details.frame = NSRect(x: 18, y: 48, width: 306, height: 17)
        thread.font = .systemFont(ofSize: 11)
        thread.textColor = .tertiaryLabelColor
        thread.lineBreakMode = .byTruncatingTail
        thread.frame = NSRect(x: 18, y: 22, width: 306, height: 18)
        for view in [title, status, speed, subtitle, chart, scope, statistics, model, effort, details, thread] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ state: MonitorState) {
        lastState = state
        title.stringValue = "Tokenometr · \(state.source)"
        let value = state.reading?.speed
        speed.stringValue = value.map { String(format: "≈ %.1f", $0) } ?? "—"
        speed.textColor = state.reading?.streaming == true ? .labelColor : .secondaryLabelColor
        status.stringValue = state.note
        status.textColor = state.reading?.streaming == true ? .systemGreen : .secondaryLabelColor
        model.stringValue = state.model
        model.toolTip = state.model
        effort.update(state.reasoningEffort)
        thread.stringValue = state.thread
        thread.toolTip = state.thread
        if let reading = state.reading {
            details.stringValue = String(format: L("≈ %d tokens  ·  %.1f s"), reading.tokens, reading.duration)
            if state.usingSavedReading, let date = state.savedAt {
                details.stringValue += "  ·  \(date.formatted(date: .omitted, time: .shortened))"
            }
        } else { details.stringValue = L("Counting response text locally") }
        if state.fragmentID != graphFragmentID || state.reading == nil {
            chart.clearInspection()
            graphFragmentID = state.fragmentID
        }
        chart.samples = state.reading?.history ?? []; chart.live = state.reading?.streaming == true
        updateStatistics()
    }

    private func updateStatistics() {
        statistics.update(lastState.reading, interval: inspectedInterval)
        if let interval = inspectedInterval {
            scope.stringValue = String(format: L("%@–%@ · ≈ %d tokens"), timelineTime(interval.start, includeUnit: false), timelineTime(interval.end), interval.tokens)
            scope.textColor = .controlAccentColor
        } else {
            scope.stringValue = lastState.reading?.history.contains(where: { $0.speed != nil }) == true
                ? (lastState.usingSavedReading ? L("Saved stats · hover to inspect") : L("Response stats · hover to inspect"))
                : L("Waiting for chart data · 2 s window")
            scope.textColor = .secondaryLabelColor
        }
    }

    func previewInspection(at time: Double) { chart.showInspection(endingAt: time) }
    func endInspection() { chart.clearInspection() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let card = MeterCard()
    private var monitor: Monitor?
    private var loginItem: NSMenuItem!
    private var displayedState: MonitorState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.horizontal", accessibilityDescription: "Tokenometr")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeft
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.title = L(" — tok/s")
        }
        let menu = NSMenu()
        menu.delegate = self
        let meterItem = NSMenuItem(); meterItem.view = card; menu.addItem(meterItem)
        menu.addItem(.separator())
        let explanation = NSMenuItem(title: L("How speed is measured"), action: nil, keyEquivalent: "")
        let help = NSMenu()
        for text in [L("Text comes from the live Codex stream"), L("Tokens are counted locally · o200k_base"),
                     L("Speed over the last 2 seconds"), L("Min / max are recorded when text arrives"),
                     L("The last measurement is saved for each chat"), L("Hidden reasoning and tools are excluded"),
                     L("≈ accounts for tokenizer differences")] {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: ""); item.isEnabled = false; help.addItem(item)
        }
        explanation.submenu = help; menu.addItem(explanation)
        loginItem = NSMenuItem(title: L("Launch at login"), action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self; menu.addItem(loginItem)
        let quit = NSMenuItem(title: L("Quit Tokenometr"), action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        statusItem.menu = menu
        do {
            let tokenizer = try Tokenizer(vocabulary: vocabularyURL())
            let home = codexHome()
            let observer = Monitor(home: home, tokenizer: tokenizer, statisticsURL: statisticsURL())
            observer.onUpdate = { [weak self] state in
                DispatchQueue.main.async { self?.display(state) }
            }
            monitor = observer; observer.start()
        } catch {
            var state = MonitorState(); state.note = L("Could not load the tokenizer")
            display(state)
        }
    }

    private func display(_ state: MonitorState) {
        guard state != displayedState else { return }
        displayedState = state
        card.update(state)
        statusItem.button?.title = state.reading?.speed.map { String(format: L(" ≈ %.1f tok/s"), $0) } ?? L(" — tok/s")
        var summary = String(format: L("%@ · %@ · Effort %@"), state.source, state.model, effortName(state.reasoningEffort))
        if let history = state.reading?.history, let end = history.last?.time,
           let interval = intervalStatistics(in: history, endingAt: end) {
            summary += String(format: L("\nOver %.1f s · ≈ %d tokens\nAverage ≈ %.1f tok/s\nMin ≈ %.1f · Max ≈ %.1f"),
                              interval.duration, interval.tokens, interval.average, interval.minimum, interval.maximum)
        } else { summary += "\n\(state.note)" }
        statusItem.button?.toolTip = summary
        statusItem.button?.appearsDisabled = !state.connected
    }

    func menuWillOpen(_ menu: NSMenu) {
        card.endInspection()
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    func menuDidClose(_ menu: NSMenu) { card.endInspection() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change launch at login")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) { monitor?.stop() }
}

func vocabularyURL() -> URL {
    Bundle.main.url(forResource: "o200k_base", withExtension: "tiktoken")
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/o200k_base.tiktoken")
}

func codexHome() -> URL {
    if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
        return URL(fileURLWithPath: override)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
}

func statisticsURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Tokenometr/statistics.json")
}

func demoState(completed: Bool = false) -> MonitorState {
    var meter = LiveMeter()
    var tokens = 7
    meter.update(tokens: tokens, at: 0)
    for i in 1...32 {
        tokens += Int((45 + sin(Double(i) * 0.4) * 9) * 0.4)
        meter.update(tokens: tokens, at: Double(i) * 0.4)
    }
    if completed { meter.finish() }
    return MonitorState(connected: true, thread: L("Interface preview"), model: "gpt-6.1-sol",
        reasoningEffort: "xhigh", reading: meter.reading(at: 12.8), fragmentID: "demo", changes: 32,
        note: completed ? L("Demo · last response") : L("Demo · measuring text arrivals"))
}

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--render-preview"), index + 1 < arguments.count {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let appearance = arguments.firstIndex(of: "--appearance").flatMap { i in
        i + 1 < arguments.count ? arguments[i + 1] : nil
    } ?? "dark"
    app.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
    let card = MeterCard()
    let window = NSWindow(contentRect: card.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
    let background = NSView(frame: card.bounds)
    background.wantsLayer = true
    app.appearance?.performAsCurrentDrawingAppearance {
        background.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
    window.contentView = background; background.addSubview(card)
    card.update(demoState())
    let previewState = arguments.firstIndex(of: "--preview-state").flatMap { i in
        i + 1 < arguments.count ? arguments[i + 1] : nil
    }
    if previewState == "waiting" {
        card.update(MonitorState(connected: true, thread: L("Interface preview"),
                                note: L("Demo · waiting for text")))
    } else if previewState == "completed" {
        card.update(demoState(completed: true))
    } else if previewState == "saved" {
        var state = demoState(completed: true)
        state.usingSavedReading = true; state.savedAt = Date()
        state.note = L("Demo · saved measurement")
        card.update(state)
    } else if previewState == "hover" {
        card.previewInspection(at: 7.2)
    } else if previewState == "cli" {
        var state = demoState(completed: true)
        state.source = "Codex CLI"; state.thread = L("Terminal session")
        state.note = L("Last response")
        card.update(state)
    }
    card.layoutSubtreeIfNeeded()
    let bitmap = background.bitmapImageRepForCachingDisplay(in: background.bounds)!
    background.cacheDisplay(in: background.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[index + 1]))
} else if arguments.contains("--preview-window") || Bundle.main.bundleIdentifier == "dev.tokenometr.preview" {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let card = MeterCard(); card.update(demoState(completed: true))
    let window = NSWindow(contentRect: card.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = L("Tokenometr · hover preview")
    window.contentView = card; window.center(); window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    app.run()
} else if arguments.contains("--diagnose") {
    let tokenizer = try Tokenizer(vocabulary: vocabularyURL())
    let file = arguments.firstIndex(of: "--statistics-file").flatMap { i in
        i + 1 < arguments.count ? URL(fileURLWithPath: arguments[i + 1]) : nil
    }
    let observer = Monitor(home: codexHome(), tokenizer: tokenizer, statisticsURL: file)
    var lastReport = 0.0
    observer.onUpdate = { state in
        let now = monotonicTime()
        if now - lastReport >= 1 {
            lastReport = now
            let report: [String: Any] = ["connected": state.connected, "source": state.source, "model": state.model,
                "reasoningEffort": state.reasoningEffort.map { $0 as Any } ?? NSNull(),
                "textChanges": state.changes, "tokens": state.reading?.tokens ?? 0,
                "tokensPerSecond": state.reading?.speed ?? 0, "streaming": state.reading?.streaming ?? false,
                "averageTokensPerSecond": state.reading?.average.map { $0 as Any } ?? NSNull(),
                "minimumTokensPerSecond": state.reading?.minimum.map { $0 as Any } ?? NSNull(),
                "maximumTokensPerSecond": state.reading?.maximum.map { $0 as Any } ?? NSNull(),
                "durationSeconds": state.reading?.duration ?? 0,
                "historySamples": state.reading?.history.count ?? 0,
                "usingSavedReading": state.usingSavedReading,
                "observedTokens": state.observedReading?.tokens ?? 0,
                "observedAverageTokensPerSecond": state.observedReading?.average.map { $0 as Any } ?? NSNull(),
                "observedHistorySamples": state.observedReading?.history.count ?? 0,
                "status": state.note]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys),
               let line = String(data: data, encoding: .utf8) { print(line); fflush(stdout) }
        }
    }
    observer.start()
    let duration = arguments.firstIndex(of: "--duration").flatMap { i in i + 1 < arguments.count ? Double(arguments[i + 1]) : nil } ?? 15
    RunLoop.main.run(until: Date().addingTimeInterval(duration))
    observer.stop()
} else {
    let app = NSApplication.shared
    // Reopening the bundle must not create a second menu bar item.
    if let bundleID = Bundle.main.bundleIdentifier,
       NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0.processIdentifier != getpid() }) {
        exit(0)
    }
    let delegate = AppDelegate(); app.delegate = delegate
    app.run()
}
