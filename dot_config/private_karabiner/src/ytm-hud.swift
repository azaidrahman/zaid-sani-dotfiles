import AppKit

// Small HUD that shows the volume of YouTube Music for Desktop.
//
// Usage: ytm-hud <0-100>
// The `ytm` script starts it after each volume change. The HUD stays for a
// short time below the menu bar, at the center of the screen, then it goes.
//
// Only one HUD is on the screen. The first process holds a lock. A new
// process finds the lock, sends its volume to the first process, and exits.
// Thus quick key presses update one HUD and do not stack HUDs.

let notificationName = Notification.Name("com.zaid.ytm-hud.volume")
let visibleTime: TimeInterval = 1.2
let fadeTime: TimeInterval = 0.25

func parseLevel(_ text: String?) -> Int? {
    guard let text, let value = Int(text) else { return nil }
    return max(0, min(100, value))
}

guard let firstLevel = parseLevel(CommandLine.arguments.dropFirst().first) else {
    FileHandle.standardError.write("usage: ytm-hud <0-100>\n".data(using: .utf8)!)
    exit(2)
}

let lockPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("ytm-hud.lock")
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
if lockFD < 0 { exit(1) }

func takeLock() -> Bool { flock(lockFD, LOCK_EX | LOCK_NB) == 0 }

if !takeLock() {
    DistributedNotificationCenter.default().postNotificationName(
        notificationName, object: String(firstLevel), userInfo: nil, deliverImmediately: true)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let width: CGFloat = 260
let height: CGFloat = 50
let barX: CGFloat = 46
let barWidth: CGFloat = 158
let barHeight: CGFloat = 6

let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
view.wantsLayer = true
view.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.88).cgColor
view.layer?.cornerRadius = 12

let icon = NSImageView(frame: NSRect(x: 14, y: 14, width: 22, height: 22))
icon.contentTintColor = .white
icon.symbolConfiguration = .init(pointSize: 16, weight: .medium)

let titleLabel = NSTextField(labelWithString: "YouTube Music")
titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
titleLabel.textColor = NSColor(white: 1, alpha: 0.6)
titleLabel.frame = NSRect(x: barX, y: 26, width: barWidth, height: 15)

let track = NSView(frame: NSRect(x: barX, y: 13, width: barWidth, height: barHeight))
track.wantsLayer = true
track.layer?.backgroundColor = NSColor(white: 1, alpha: 0.2).cgColor
track.layer?.cornerRadius = barHeight / 2

let fill = CALayer()
fill.backgroundColor = NSColor.white.cgColor
fill.cornerRadius = barHeight / 2
track.layer?.addSublayer(fill)

let percentLabel = NSTextField(labelWithString: "")
percentLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
percentLabel.textColor = .white
percentLabel.alignment = .right
percentLabel.frame = NSRect(x: barX + barWidth + 4, y: 9, width: width - barX - barWidth - 18, height: 18)

view.addSubview(icon)
view.addSubview(titleLabel)
view.addSubview(track)
view.addSubview(percentLabel)

func symbolName(_ level: Int) -> String {
    switch level {
    case 0: return "speaker.slash.fill"
    case ..<34: return "speaker.wave.1.fill"
    case ..<67: return "speaker.wave.2.fill"
    default: return "speaker.wave.3.fill"
    }
}

func show(_ level: Int) {
    icon.image = NSImage(systemSymbolName: symbolName(level), accessibilityDescription: "Volume")
    percentLabel.stringValue = "\(level)%"
    fill.frame = CGRect(x: 0, y: 0, width: barWidth * CGFloat(level) / 100, height: barHeight)
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
w.ignoresMouseEvents = true
w.hidesOnDeactivate = false
w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
w.contentView = view

// Put the HUD at the top center of the screen, below the menu bar.
if let screen = NSScreen.main {
    let vf = screen.visibleFrame
    w.setFrameOrigin(NSPoint(x: vf.midX - width / 2, y: vf.maxY - height - 12))
}

var hideTimer: Timer?
var fading = false

func scheduleHide() {
    hideTimer?.invalidate()
    hideTimer = Timer.scheduledTimer(withTimeInterval: visibleTime, repeats: false) { _ in
        // Release the lock first. A process that starts during the fade then
        // shows its own HUD, so no volume change is lost.
        flock(lockFD, LOCK_UN)
        fading = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fadeTime
            w.animator().alphaValue = 0
        }, completionHandler: {
            if fading { app.terminate(nil) }
        })
    }
}

// A selector observer runs on the main thread, as the run loop delivers it.
final class VolumeObserver: NSObject {
    @objc func received(_ note: Notification) {
        guard let level = parseLevel(note.object as? String) else { return }
        if fading {
            // Another process can own the lock now. Then that process shows
            // the volume, and this HUD continues to fade.
            guard takeLock() else { return }
            fading = false
            w.alphaValue = 1
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        show(level)
        CATransaction.commit()
        scheduleHide()
    }
}

let observer = VolumeObserver()
DistributedNotificationCenter.default().addObserver(
    observer, selector: #selector(VolumeObserver.received(_:)), name: notificationName, object: nil)

CATransaction.begin()
CATransaction.setDisableActions(true)
show(firstLevel)
CATransaction.commit()
w.orderFrontRegardless()
scheduleHide()
app.run()
