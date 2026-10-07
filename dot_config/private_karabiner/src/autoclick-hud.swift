import AppKit
import ApplicationServices

// autoclick-hud
//
// An autoclicker with an on-screen indicator. The first run asks for the
// number of clicks each second, or takes it from --rate. It then clicks at
// the pointer until one of these events occurs:
//
//   - A second run of this binary. The second run stops the first run.
//   - The pointer moves more than the radius from the start point.
//   - The time limit ends. In the last minute, the time shows in orange.
//
//   autoclick-hud [--radius <points>] [--limit <minutes>] [--rate <clicks>]
//   autoclick-hud --hold --rate <clicks> [--limit <minutes>]
//   autoclick-hud --stop
//
// The default radius is 10 points. The default limit is 30 minutes. The
// Karabiner bindings set both values. If --rate is set, the binary starts
// at once and does not show the prompt.
//
// Hold mode is for a key that is held down. Karabiner starts it when Right
// Shift and the mouse button are held, and runs --stop when the button goes
// up. It does not stop when the pointer moves, and it does not stop an
// active run. Each hold starts at --rate.
//
// --stop also touches stopFile. A hold run stops if stopFile is newer than
// its start. Thus a quick release that runs --stop before the hold run
// writes its pid file still stops the hold run.
//
// While it clicks, the scroll wheel changes the rate. Scroll up to click
// faster, and scroll down to click slower. The binary keeps the scroll
// events, so the window below does not scroll. One step occurs each
// scrollStepInterval at most, thus one long scroll changes the rate by
// about 5.
//
// First-run permission: needs Accessibility (System Settings → Privacy &
// Security → Accessibility), because the binary posts mouse events. The
// binary opens the system prompt on first run.

let pidFile = "/tmp/autoclick-hud.pid"
let stopFile = "/tmp/autoclick-hud.stop"
let launchTime = Date()
let stateDir = ("~/.local/state/autoclick-hud" as NSString).expandingTildeInPath
let rateFile = stateDir + "/rate"

let defaultRadius: CGFloat = 10
let defaultLimitMinutes = 30.0
let maxRate = 100
let scrollStepInterval = 0.08

// The pid of the active run. The name check makes sure that a stale pid
// file never stops an unrelated process that got the pid.
func runningPid() -> pid_t? {
    guard let raw = try? String(contentsOfFile: pidFile, encoding: .utf8),
          let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          pid != getpid(), kill(pid, 0) == 0
    else { return nil }
    var name = [CChar](repeating: 0, count: 256)
    proc_name(pid, &name, UInt32(name.count))
    return String(cString: name) == "autoclick-hud" ? pid : nil
}

func positiveFlag(_ name: String) -> Double? {
    guard let i = CommandLine.arguments.firstIndex(of: name),
          i + 1 < CommandLine.arguments.count,
          let value = Double(CommandLine.arguments[i + 1]), value > 0
    else { return nil }
    return value
}

let radius = positiveFlag("--radius").map { CGFloat($0) } ?? defaultRadius
let limit = (positiveFlag("--limit") ?? defaultLimitMinutes) * 60
let hold = CommandLine.arguments.contains("--hold")

func readRate(_ path: String) -> Int? {
    (try? String(contentsOfFile: path, encoding: .utf8))
        .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

func clampRate(_ rate: Int) -> Int { min(maxRate, max(1, rate)) }

let fixedRate = positiveFlag("--rate").map { clampRate(Int($0)) }

if CommandLine.arguments.contains("--stop") {
    FileManager.default.createFile(atPath: stopFile, contents: nil)
    if let pid = runningPid() { kill(pid, SIGTERM) }
    exit(0)
}

// Toggle: if a run is active, stop it and exit. In hold mode, keep it.
if let pid = runningPid() {
    if !hold { kill(pid, SIGTERM) }
    exit(0)
}

let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
if !AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) {
    FileHandle.standardError.write(
        Data("autoclick-hud: Accessibility not yet granted; system prompt opened.\n".utf8))
    exit(1)
}

try? "\(getpid())".write(toFile: pidFile, atomically: true, encoding: .utf8)

func quit() -> Never {
    // Remove the pid file only if it is still ours.
    if let raw = try? String(contentsOfFile: pidFile, encoding: .utf8),
       raw.trimmingCharacters(in: .whitespacesAndNewlines) == "\(getpid())" {
        try? FileManager.default.removeItem(atPath: pidFile)
    }
    exit(0)
}

// A second run sends SIGTERM. The handler runs on the main queue, so the
// clean exit does not race the click timer.
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler { quit() }
termSource.resume()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
NSApp.appearance = NSAppearance(named: .darkAqua)

// The same colours and fonts as timer-hud.
let hudAccent = NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1.0)
let hudRed = NSColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 1.0)
let hudOrange = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1.0)

func hudGray(_ white: CGFloat, _ alpha: CGFloat) -> NSColor {
    NSColor(srgbRed: white, green: white, blue: white, alpha: alpha)
}

func hudFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let name = weight == .medium ? "SFProText-Medium" : "SFProText-Regular"
    return NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
}

// CGEvent uses global coordinates with a top-left origin. NSEvent uses a
// bottom-left origin. The click code stays in CGEvent coordinates.
func pointerLocation() -> CGPoint {
    CGEvent(source: nil)?.location ?? .zero
}

func screenUnderPointer() -> NSScreen? {
    let p = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class PromptDelegate: NSObject, NSTextFieldDelegate {
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onSubmit?(control.stringValue)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let filtered = field.stringValue.filter { $0.isNumber }
        if filtered != field.stringValue { field.stringValue = filtered }
    }
}

// MARK: - Indicator

// The indicator is a pill at the top of the screen under the pointer. It
// ignores mouse events, so a click on it goes to the window below.
var titleLabel: NSTextField!
var timeLabel: NSTextField!

func clock(_ seconds: Double) -> String {
    let total = Int(seconds)
    return String(format: "%d:%02d", total / 60, total % 60)
}

func showIndicator(rate: Int) -> NSPanel {
    let width: CGFloat = 330
    let height: CGFloat = 52

    let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    root.wantsLayer = true
    root.layer?.backgroundColor = hudGray(0.1, 0.9).cgColor
    root.layer?.cornerRadius = 14

    let dot = NSView(frame: NSRect(x: 16, y: height / 2 - 5, width: 10, height: 10))
    dot.wantsLayer = true
    dot.layer?.backgroundColor = hudRed.cgColor
    dot.layer?.cornerRadius = 5
    let pulse = CABasicAnimation(keyPath: "opacity")
    pulse.fromValue = 1.0
    pulse.toValue = 0.25
    pulse.duration = 0.6
    pulse.autoreverses = true
    pulse.repeatCount = .infinity
    dot.layer?.add(pulse, forKey: "pulse")
    root.addSubview(dot)

    titleLabel = NSTextField(labelWithString: "Autoclicking · \(rate)/s")
    titleLabel.font = hudFont(ofSize: 14, weight: .medium)
    titleLabel.textColor = hudGray(1, 1)
    titleLabel.frame = NSRect(x: 36, y: 25, width: 180, height: 18)
    root.addSubview(titleLabel)

    timeLabel = NSTextField(labelWithString: "0:00 / \(clock(limit))")
    timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    timeLabel.textColor = hudGray(1, 0.55)
    timeLabel.alignment = .right
    timeLabel.frame = NSRect(x: width - 116, y: 25, width: 100, height: 18)
    root.addSubview(timeLabel)

    let hint = NSTextField(
        labelWithString: hold
            ? "Scroll to change speed · release to stop"
            : "Scroll to change speed · move the mouse to stop")
    hint.font = hudFont(ofSize: 11, weight: .regular)
    hint.textColor = hudGray(1, 0.4)
    hint.frame = NSRect(x: 36, y: 8, width: width - 52, height: 15)
    root.addSubview(hint)

    let panel = NSPanel(
        contentRect: root.frame,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .statusBar
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    panel.contentView = root
    panel.appearance = NSAppearance(named: .darkAqua)

    if let screen = screenUnderPointer() {
        let vf = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: vf.midX - width / 2, y: vf.maxY - height - 12))
    }
    panel.orderFrontRegardless()
    return panel
}

// MARK: - Clicking

func postClick(at point: CGPoint) {
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left)
        else { continue }
        // Each click is a single click. Without this, an app can read two
        // fast clicks at one point as a double click.
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        // The trigger can be a shift+click. Clear the flags, so that a
        // shift key that is still down does not make a shift+click.
        event.flags = []
        event.post(tap: .cghidEventTap)
    }
}

// The stop of the previous hold occurs at least one held-down threshold
// before this start. The margin covers the time from the press to launch.
func stopRequested() -> Bool {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: stopFile),
          let modified = attrs[.modificationDate] as? Date
    else { return false }
    return modified > launchTime.addingTimeInterval(-0.15)
}

var clickTimer: Timer?
var currentRate = 0
var anchor = CGPoint.zero
var indicator: NSPanel?

func scheduleClicks(rate: Int) {
    currentRate = rate
    clickTimer?.invalidate()
    let timer = Timer(timeInterval: 1.0 / Double(rate), repeats: true) { _ in
        let p = pointerLocation()
        if (hold && stopRequested()) || (!hold && hypot(p.x - anchor.x, p.y - anchor.y) > radius) {
            indicator?.orderOut(nil)
            quit()
        }
        postClick(at: p)
    }
    // The common mode keeps the timer active while a menu or a drag is open.
    RunLoop.main.add(timer, forMode: .common)
    clickTimer = timer
    titleLabel?.stringValue = "Autoclicking · \(rate)/s"
}

// MARK: - Scroll to change the rate

var lastScrollStep = Date.distantPast
var scrollTap: CFMachPort?

func handleScroll(_ event: CGEvent) {
    // A trackpad sends momentum events after the fingers lift. Ignore them,
    // so that one gesture does not continue to change the rate.
    guard event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 else { return }
    let delta = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
    guard delta != 0, Date().timeIntervalSince(lastScrollStep) >= scrollStepInterval
    else { return }
    lastScrollStep = Date()
    let rate = clampRate(currentRate + (delta > 0 ? 1 : -1))
    if rate != currentRate { scheduleClicks(rate: rate) }
}

func startScrollTap() {
    let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
    let callback: CGEventTapCallBack = { _, type, event, _ in
        // The system turns off a tap that is too slow. Turn it on again.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = scrollTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        handleScroll(event)
        return nil
    }
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: .defaultTap, eventsOfInterest: mask,
                                      callback: callback, userInfo: nil)
    else { return }
    scrollTap = tap
    let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
}

func startClicking(rate: Int) {
    anchor = pointerLocation()
    indicator = showIndicator(rate: rate)
    scheduleClicks(rate: rate)
    startScrollTap()

    // A separate clock timer updates the time, so that a slow click rate
    // does not make the time jump.
    let start = Date()
    let clockTimer = Timer(timeInterval: 0.25, repeats: true) { _ in
        let elapsed = Date().timeIntervalSince(start)
        if elapsed >= limit {
            indicator?.orderOut(nil)
            quit()
        }
        timeLabel.stringValue = "\(clock(elapsed)) / \(clock(limit))"
        if limit - elapsed <= 60 { timeLabel.textColor = hudOrange }
    }

    RunLoop.main.add(clockTimer, forMode: .common)
}

// With --rate, start at once and do not open the prompt. app.run() does not
// return, because each stop goes through quit().
if let rate = fixedRate {
    DispatchQueue.main.async { startClicking(rate: rate) }
    app.run()
}

// MARK: - Prompt

let previous = NSWorkspace.shared.frontmostApplication
let lastRate = readRate(rateFile) ?? 10

let panelWidth: CGFloat = 470
let panelHeight: CGFloat = 118

let root = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
root.wantsLayer = true
root.layer?.backgroundColor = hudGray(0.1, 0.95).cgColor
root.layer?.cornerRadius = 14

let head = NSTextField(labelWithString: "How many clicks each second?")
head.font = hudFont(ofSize: 15, weight: .medium)
head.textColor = hudGray(1, 1)
head.alignment = .center
head.frame = NSRect(x: 14, y: panelHeight - 34, width: panelWidth - 28, height: 20)
root.addSubview(head)

let field = NSTextField(frame: NSRect(x: 24, y: 44, width: panelWidth - 48, height: 28))
field.font = hudFont(ofSize: 14, weight: .regular)
field.stringValue = "\(lastRate)"
field.placeholderString = "1 to \(maxRate)"
field.wantsLayer = true
field.layer?.cornerRadius = 8
field.focusRingType = .none
field.bezelStyle = .roundedBezel
root.addSubview(field)

let hint = NSTextField(labelWithString:
    "1 to \(maxRate) · ⏎ starts at the pointer · esc cancels")
hint.font = hudFont(ofSize: 11, weight: .regular)
hint.textColor = hudGray(1, 0.35)
hint.alignment = .center
hint.frame = NSRect(x: 14, y: 12, width: panelWidth - 28, height: 15)
root.addSubview(hint)

let prompt = KeyPanel(
    contentRect: root.frame,
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
prompt.isOpaque = false
prompt.backgroundColor = .clear
prompt.level = .floating
prompt.hasShadow = true
prompt.contentView = root
prompt.appearance = NSAppearance(named: .darkAqua)

if let screen = screenUnderPointer() {
    let sf = screen.frame
    prompt.setFrameOrigin(NSPoint(x: sf.midX - panelWidth / 2,
                                  y: sf.midY - panelHeight / 2))
}

let delegate = PromptDelegate()
delegate.onCancel = {
    previous?.activate(options: [])
    quit()
}
delegate.onSubmit = { text in
    guard let rate = Int(text), (1...maxRate).contains(rate) else {
        NSSound.beep()
        return
    }
    try? FileManager.default.createDirectory(
        atPath: stateDir, withIntermediateDirectories: true)
    try? "\(rate)".write(toFile: rateFile, atomically: true, encoding: .utf8)

    prompt.orderOut(nil)
    previous?.activate(options: [])
    // Wait for the focus to go back to the previous app, so that the first
    // click does not land while the prompt still holds the focus.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        startClicking(rate: rate)
    }
}
field.delegate = delegate

// A prompt that nobody answers closes after 60 seconds.
DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
    if clickTimer == nil {
        previous?.activate(options: [])
        quit()
    }
}

// NSTextField.delegate is a weak reference, so keep the delegate alive.
withExtendedLifetime(delegate) {
    prompt.makeKeyAndOrderFront(nil)
    prompt.makeFirstResponder(field)
    field.currentEditor()?.selectAll(nil)
    app.activate(ignoringOtherApps: true)
    app.run()
}
