import AppKit

// Small HUD that shows a change in YouTube Music for Desktop.
//
// Usage:
//   ytm-hud volume <0-100>
//   ytm-hud seek <delta> <position> <duration>    (all in seconds)
// The `ytm` script starts it after each volume change and each seek. The HUD
// stays for a short time below the menu bar, at the center of the screen,
// then it goes.
//
// Only one HUD is on the screen. The first process holds a lock. A new
// process finds the lock, sends its arguments to the first process, and
// exits. Thus quick key presses update one HUD and do not stack HUDs.

let notificationName = Notification.Name("com.zaid.ytm-hud.update")
let visibleTime: TimeInterval = 1.2
let fadeTime: TimeInterval = 0.25

enum Reading {
    case volume(Int)
    case seek(delta: Int, position: Int, duration: Int)
}

func parse(_ words: [String]) -> Reading? {
    let numbers = words.dropFirst().compactMap { Int($0) }
    guard numbers.count == words.count - 1 else { return nil }
    switch (words.first, numbers.count) {
    case ("volume", 1):
        return .volume(max(0, min(100, numbers[0])))
    case ("seek", 3):
        let duration = max(0, numbers[2])
        var position = max(0, numbers[1])
        if duration > 0 { position = min(duration, position) }
        return .seek(delta: numbers[0], position: position, duration: duration)
    default:
        return nil
    }
}

let firstWords = Array(CommandLine.arguments.dropFirst())
guard let firstReading = parse(firstWords) else {
    FileHandle.standardError.write(
        "usage: ytm-hud volume <0-100> | ytm-hud seek <delta> <position> <duration>\n".data(using: .utf8)!)
    exit(2)
}

let lockPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("ytm-hud.lock")
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
if lockFD < 0 { exit(1) }

func takeLock() -> Bool { flock(lockFD, LOCK_EX | LOCK_NB) == 0 }

if !takeLock() {
    DistributedNotificationCenter.default().postNotificationName(
        notificationName, object: firstWords.joined(separator: " "), userInfo: nil, deliverImmediately: true)
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

let valueLabel = NSTextField(labelWithString: "")
valueLabel.textColor = .white
valueLabel.alignment = .right
valueLabel.frame = NSRect(x: barX + barWidth + 4, y: 9, width: width - barX - barWidth - 18, height: 18)

view.addSubview(icon)
view.addSubview(titleLabel)
view.addSubview(track)
view.addSubview(valueLabel)

func volumeSymbol(_ level: Int) -> String {
    switch level {
    case 0: return "speaker.slash.fill"
    case ..<34: return "speaker.wave.1.fill"
    case ..<67: return "speaker.wave.2.fill"
    default: return "speaker.wave.3.fill"
    }
}

// 83 -> "1:23", 3723 -> "1:02:03"
func clock(_ seconds: Int) -> String {
    let h = seconds / 3600, m = seconds / 60 % 60, s = seconds % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

// Make the font smaller until the text fits, so "+120s" does not get cut.
func setValue(_ text: String) {
    valueLabel.stringValue = text
    var size: CGFloat = 13
    repeat {
        valueLabel.font = .monospacedDigitSystemFont(ofSize: size, weight: .medium)
        size -= 1
    } while size >= 9 && valueLabel.attributedStringValue.size().width > valueLabel.frame.width - 4
}

func show(_ reading: Reading) {
    let fraction: CGFloat
    switch reading {
    case .volume(let level):
        icon.image = NSImage(systemSymbolName: volumeSymbol(level), accessibilityDescription: "Volume")
        titleLabel.stringValue = "YouTube Music"
        setValue("\(level)%")
        fraction = CGFloat(level) / 100
    case .seek(let delta, let position, let duration):
        let name = delta < 0 ? "gobackward" : "goforward"
        icon.image = NSImage(systemSymbolName: name, accessibilityDescription: "Seek")
        titleLabel.stringValue = duration > 0 ? "\(clock(position)) / \(clock(duration))" : clock(position)
        setValue((delta < 0 ? "\u{2212}" : "+") + "\(abs(delta))s")
        fraction = duration > 0 ? CGFloat(position) / CGFloat(duration) : 0
    }
    fill.frame = CGRect(x: 0, y: 0, width: barWidth * fraction, height: barHeight)
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
        // shows its own HUD, so no change is lost.
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
final class UpdateObserver: NSObject {
    @objc func received(_ note: Notification) {
        guard let text = note.object as? String,
              let reading = parse(text.split(separator: " ").map(String.init)) else { return }
        if fading {
            // Another process can own the lock now. Then that process shows
            // the change, and this HUD continues to fade.
            guard takeLock() else { return }
            fading = false
            w.alphaValue = 1
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        show(reading)
        CATransaction.commit()
        scheduleHide()
    }
}

let observer = UpdateObserver()
DistributedNotificationCenter.default().addObserver(
    observer, selector: #selector(UpdateObserver.received(_:)), name: notificationName, object: nil)

CATransaction.begin()
CATransaction.setDisableActions(true)
show(firstReading)
CATransaction.commit()
w.orderFrontRegardless()
scheduleHide()
app.run()
