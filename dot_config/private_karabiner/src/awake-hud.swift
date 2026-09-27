import AppKit
import IOKit.pwr_mgt

// Badge that keeps the Mac awake while it is on the screen.
//
// The process holds two power assertions: one stops the display sleep, and
// one stops the system sleep. The kernel releases the assertions when the
// process exits, also after a crash. Thus the Mac cannot stay awake by
// mistake after the badge is gone.
//
// Usage: awake-hud [seconds]
// With no argument, the badge stays until you click it.
// A click on the badge ends the process. The `awake` wrapper starts it.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let limit: TimeInterval? = CommandLine.arguments.dropFirst().first.flatMap {
    TimeInterval($0)
}
let startedAt = Date()
let endsAt = limit.map { startedAt.addingTimeInterval($0) }

var assertions: [IOPMAssertionID] = []
for type in [kIOPMAssertionTypePreventUserIdleDisplaySleep,
             kIOPMAssertionTypePreventSystemSleep] {
    var id: IOPMAssertionID = 0
    let result = IOPMAssertionCreateWithName(
        type as CFString,
        IOPMAssertionLevel(kIOPMAssertionLevelOn),
        "awake-hud: keep the Mac awake" as CFString,
        &id)
    if result == kIOReturnSuccess {
        assertions.append(id)
    } else {
        FileHandle.standardError.write("awake-hud: assertion failed: \(result)\n".data(using: .utf8)!)
    }
}
if assertions.isEmpty { exit(1) }

func stop() {
    for id in assertions { IOPMAssertionRelease(id) }
    app.terminate(nil)
}

func clock(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds.rounded()))
    let (h, m, sec) = (s / 3600, s % 3600 / 60, s % 60)
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                 : String(format: "%d:%02d", m, sec)
}

let untilFormat = DateFormatter()
untilFormat.dateFormat = "HH:mm"

// A click anywhere on the badge ends the process.
final class BadgeView: NSView {
    override func mouseDown(with event: NSEvent) { stop() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

let width: CGFloat = 178
let height: CGFloat = 44

let view = BadgeView(frame: NSRect(x: 0, y: 0, width: width, height: height))
view.wantsLayer = true
view.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.88).cgColor
view.layer?.cornerRadius = 12
view.toolTip = "Click to let the Mac sleep again"

let titleLabel = NSTextField(labelWithString: "☕  Awake")
titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
titleLabel.textColor = .white
titleLabel.frame = NSRect(x: 12, y: 21, width: width - 24, height: 18)

let detailLabel = NSTextField(labelWithString: "")
detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
detailLabel.textColor = NSColor(white: 1, alpha: 0.6)
detailLabel.frame = NSRect(x: 12, y: 5, width: width - 24, height: 15)

view.addSubview(titleLabel)
view.addSubview(detailLabel)

func refresh() {
    let now = Date()
    if let endsAt {
        let left = endsAt.timeIntervalSince(now)
        if left <= 0 { stop(); return }
        detailLabel.stringValue = "\(clock(left)) left · until \(untilFormat.string(from: endsAt))"
    } else {
        detailLabel.stringValue = "on for \(clock(now.timeIntervalSince(startedAt))) · click to stop"
    }
}

let w = NSPanel(
    contentRect: view.frame,
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
w.isOpaque = false
w.backgroundColor = .clear
w.level = .statusBar
w.hasShadow = true
w.hidesOnDeactivate = false
w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
w.contentView = view

// Put the badge in the top-right corner, below the menu bar.
if let screen = NSScreen.main {
    let vf = screen.visibleFrame
    w.setFrameOrigin(NSPoint(x: vf.maxX - width - 12, y: vf.maxY - height - 12))
}

// `killall awake-hud` sends SIGTERM. Catch it, so that the process exits
// through the same path as a click.
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler { stop() }
term.resume()

refresh()
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in refresh() }
w.orderFrontRegardless()
app.run()
