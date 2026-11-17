import AppKit

// Mini player for YouTube Music for Desktop (YTMDesktop2).
//
// The player is a small panel that stays on top of the other windows. It
// shows the album art, the title, the artist, and the position of the current
// track. When the pointer is on the panel, the panel becomes almost
// transparent, and clicks go through it. Hold Option to make it solid again.
// Then it shows buttons for previous, play/pause, next, and like, and you can
// drag it.
//
// The panel goes on the second monitor from the left. AeroSpace numbers the
// monitors in the same order, so this is AeroSpace monitor 2. If only one
// monitor is connected, the panel is hidden. The panel is a non-activating
// panel, and AeroSpace does not manage it. Thus the panel stays on the screen
// when you change the workspace.
//
// The panel is hidden also when YouTube Music does not run, or when no track
// is loaded. Drag the panel to move it. The position is kept as an offset from
// the bottom-right corner of the monitor.
//
// The LaunchAgent com.zaid.ytm-mini starts this program at login.
//
// Usage:
//   ytm-mini                              Run the player.
//   ytm-mini toggle|show|hide|reset       Send a command to the player.
// "hide" keeps the player hidden until "show" or "toggle". "reset" puts the
// player back in the bottom-right corner. "ytm mini" runs these commands.
//
// The program reads the Local API at http://127.0.0.1:13091 one time each
// second. If ${XDG_DATA_HOME:-~/.local/share}/ytm/token exists, the program
// sends the token. "ytm pair" makes the token.

let commandName = Notification.Name("com.zaid.ytm-mini.command")
let commands: Set = ["toggle", "show", "hide", "reset"]
let defaults = UserDefaults(suiteName: "com.zaid.ytm-mini")!

let args = Array(CommandLine.arguments.dropFirst())
if let word = args.first {
    guard args.count == 1, commands.contains(word) else {
        FileHandle.standardError.write("usage: ytm-mini [toggle|show|hide|reset]\n".data(using: .utf8)!)
        exit(2)
    }
    DistributedNotificationCenter.default().postNotificationName(
        commandName, object: word, userInfo: nil, deliverImmediately: true)
    exit(0)
}

// Only one player runs. A second player exits, for example when you start
// the program by hand while the LaunchAgent runs it.
let lockPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("ytm-mini.lock")
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    FileHandle.standardError.write("ytm-mini: the player already runs\n".data(using: .utf8)!)
    exit(0)
}

let base = "http://127.0.0.1:\(ProcessInfo.processInfo.environment["YTM_PORT"] ?? "13091")"
let tokenPath: String = {
    let env = ProcessInfo.processInfo.environment
    let data = env["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        ?? (NSHomeDirectory() as NSString).appendingPathComponent(".local/share")
    return (data as NSString).appendingPathComponent("ytm/token")
}()

// MARK: - Local API

struct PlayerState {
    var id: String
    var playing: Bool
    var progress: Double
    var duration: Double
    var liked: Bool
    var accent: NSColor?
}

let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 2
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: config)
}()

// The token can change after "ytm pair", so read the file for each request.
func request(_ method: String, _ path: String, body: String? = nil) -> URLRequest {
    var req = URLRequest(url: URL(string: base + path)!)
    req.httpMethod = method
    if let token = try? String(contentsOfFile: tokenPath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let body = body {
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.data(using: .utf8)
    }
    return req
}

// The reason of the last failed request, for the log.
var lastFailure = ""

// The completion handler runs on the main thread. It gets nil on any error.
func call(_ method: String, _ path: String, body: String? = nil, _ done: @escaping (Data?) -> Void) {
    session.dataTask(with: request(method, path, body: body)) { data, response, error in
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let ok = error == nil && status / 100 == 2
        DispatchQueue.main.async {
            if !ok {
                lastFailure = error.map { "\(path): \($0.localizedDescription)" } ?? "\(path): HTTP \(status)"
            }
            done(ok ? data : nil)
        }
    }.resume()
}

// The LaunchAgent sends stdout to ~/Library/Logs/ytm-mini.log.
let stamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func note(_ text: String) {
    print("\(stamp.string(from: Date())) \(text)")
    fflush(stdout)
}

func json(_ data: Data?) -> [String: Any]? {
    guard let data = data else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

// "#a8603c" -> NSColor
func color(hex: String?) -> NSColor? {
    guard var s = hex, s.hasPrefix("#") else { return nil }
    s.removeFirst()
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                   green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

func parseState(_ d: [String: Any]) -> PlayerState? {
    guard let id = d["id"] as? String, !id.isEmpty else { return nil }
    return PlayerState(
        id: id,
        playing: d["playing"] as? Bool ?? false,
        progress: d["progress"] as? Double ?? 0,
        duration: d["duration"] as? Double ?? 0,
        liked: d["liked"] as? Bool ?? false,
        accent: color(hex: d["accent"] as? String))
}

// MARK: - Views

// The panel never becomes the key window. A button in a window that is not
// the key window ignores the first click, unless it accepts the first mouse.
final class Button: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // The panel moves when you drag its background. Do not move it when a
    // drag starts on a button.
    override var mouseDownCanMoveWindow: Bool { false }

    var action_: (() -> Void)?

    convenience init(symbol: String, size: CGFloat, _ action: @escaping () -> Void) {
        self.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        contentTintColor = .white
        symbolConfiguration = .init(pointSize: size, weight: .semibold)
        // A shadow keeps the white symbol clear on light album art.
        let glow = NSShadow()
        glow.shadowColor = NSColor(white: 0, alpha: 0.6)
        glow.shadowBlurRadius = 6
        shadow = glow
        setSymbol(symbol)
        action_ = action
        target = self
        self.action = #selector(fire)
    }

    func setSymbol(_ name: String) {
        image = NSImage(systemSymbolName: name, accessibilityDescription: name)
    }

    @objc func fire() { action_?() }
}

let width: CGFloat = 300
let height: CGFloat = 300
let margin: CGFloat = 12
let inset: CGFloat = 14
let innerWidth = width - 2 * inset
let barHeight: CGFloat = 3

final class RootView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

let root = RootView(frame: NSRect(x: 0, y: 0, width: width, height: height))
root.wantsLayer = true
root.layer?.cornerRadius = 14
root.layer?.masksToBounds = true

let background = NSColor(white: 0.08, alpha: 1)
root.layer?.backgroundColor = background.cgColor

// The album art fills the panel. The text goes on a dark gradient at the
// bottom of the art.
let artLayer = CALayer()
artLayer.frame = root.bounds
artLayer.contentsGravity = .resizeAspectFill
artLayer.masksToBounds = true
root.layer?.addSublayer(artLayer)

let shade = CAGradientLayer()
shade.frame = CGRect(x: 0, y: 0, width: width, height: 130)
shade.colors = [NSColor(white: 0, alpha: 0.85).cgColor, NSColor(white: 0, alpha: 0).cgColor]
shade.startPoint = CGPoint(x: 0.5, y: 0)
shade.endPoint = CGPoint(x: 0.5, y: 1)
root.layer?.addSublayer(shade)

func label(size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) -> NSTextField {
    let l = NSTextField(labelWithString: "")
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = NSColor(white: 1, alpha: alpha)
    l.lineBreakMode = .byTruncatingTail
    l.cell?.truncatesLastVisibleLine = true
    return l
}

let timeWidth: CGFloat = 84
let textGroup = NSView(frame: NSRect(x: inset, y: 24, width: innerWidth, height: 40))
let titleLabel = label(size: 15, weight: .semibold, alpha: 1)
titleLabel.frame = NSRect(x: 0, y: 19, width: innerWidth, height: 20)
let artistLabel = label(size: 12, weight: .regular, alpha: 0.7)
artistLabel.frame = NSRect(x: 0, y: 1, width: innerWidth - timeWidth - 6, height: 16)
let timeLabel = NSTextField(labelWithString: "")
timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
timeLabel.textColor = NSColor(white: 1, alpha: 0.6)
timeLabel.alignment = .right
timeLabel.frame = NSRect(x: innerWidth - timeWidth, y: 1, width: timeWidth, height: 16)
textGroup.addSubview(titleLabel)
textGroup.addSubview(artistLabel)
textGroup.addSubview(timeLabel)

let barTrack = CALayer()
barTrack.frame = CGRect(x: inset, y: 14, width: innerWidth, height: barHeight)
barTrack.backgroundColor = NSColor(white: 1, alpha: 0.25).cgColor
barTrack.cornerRadius = barHeight / 2
let barFill = CALayer()
barFill.backgroundColor = NSColor.white.cgColor
barFill.cornerRadius = barHeight / 2
barTrack.addSublayer(barFill)

// The control group darkens the art and holds the buttons. It shows only
// while Option is held.
let controlGroup = NSView(frame: root.bounds)
controlGroup.wantsLayer = true
controlGroup.layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
controlGroup.alphaValue = 0
controlGroup.isHidden = true

var current: PlayerState?

func send(_ path: String, body: String? = nil) {
    call("POST", path, body: body) { _ in poll() }
}

let prevButton = Button(symbol: "backward.fill", size: 20) { send("/track/prev") }
let playButton = Button(symbol: "play.fill", size: 30) { send("/track/toggle-play-state") }
let nextButton = Button(symbol: "forward.fill", size: 20) { send("/track/next") }
// The API sets the like state. It does not toggle it.
let likeButton = Button(symbol: "heart", size: 18) {
    send("/track/like", body: (current?.liked ?? false) ? "false" : "true")
}

do {
    let buttons = [prevButton, playButton, nextButton]
    let slot: CGFloat = 70
    let left = (width - slot * CGFloat(buttons.count)) / 2
    // Center the buttons in the part of the art above the text.
    let mid = 70 + (height - 70 - 56) / 2
    for (i, b) in buttons.enumerated() {
        b.frame = NSRect(x: left + CGFloat(i) * slot, y: mid, width: slot, height: 56)
        controlGroup.addSubview(b)
    }
    likeButton.frame = NSRect(x: width - 44, y: controlGroup.bounds.height - 44, width: 36, height: 36)
    controlGroup.addSubview(likeButton)
}

// The control group goes below the text, so the text stays bright.
root.addSubview(controlGroup)
root.layer?.addSublayer(barTrack)
root.addSubview(textGroup)

// MARK: - Panel and position

final class Panel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let playerPanel = Panel(
    contentRect: root.frame,
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false)
playerPanel.isOpaque = false
playerPanel.backgroundColor = .clear
playerPanel.hasShadow = true
playerPanel.level = .floating
playerPanel.hidesOnDeactivate = false
playerPanel.isMovableByWindowBackground = true
playerPanel.ignoresMouseEvents = true
playerPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
playerPanel.contentView = root

// The panel has three looks:
//   rest     The pointer is not on the panel. The panel is solid.
//   peek     The pointer is on the panel. The panel is almost transparent,
//            and clicks go through it to the window below.
//   active   The pointer is on the panel and Option is held. The panel is
//            solid, it takes clicks, and it shows the buttons.
// A window that ignores mouse events gets no mouse-entered events. Thus a
// timer reads the pointer position and the Option key.
enum Look { case rest, peek, active }
var look = Look.rest
let peekAlpha: CGFloat = 0.15

func setLook(_ new: Look) {
    guard new != look else { return }
    look = new
    playerPanel.ignoresMouseEvents = new != .active
    if new == .active { controlGroup.isHidden = false }
    NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = 0.15
        playerPanel.animator().alphaValue = new == .peek ? peekAlpha : 1
        controlGroup.animator().alphaValue = new == .active ? 1 : 0
    }, completionHandler: {
        if look != .active { controlGroup.isHidden = true }
    })
}

func updateLook() {
    guard playerPanel.isVisible else { return setLook(.rest) }
    // Keep the look while a drag moves the panel, because the pointer can
    // leave the frame for a moment.
    if look == .active && NSEvent.pressedMouseButtons != 0 { return }
    let inside = NSMouseInRect(NSEvent.mouseLocation, playerPanel.frame, false)
    let option = NSEvent.modifierFlags.contains(.option)
    setLook(!inside ? .rest : option ? .active : .peek)
}

Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in updateLook() }

// The second monitor from the left, or nil if only one monitor is connected.
func targetScreen() -> NSScreen? {
    let screens = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
    return screens.count >= 2 ? screens[1] : nil
}

// The offset of the bottom-right corner of the panel from the bottom-right
// corner of the visible frame of the monitor.
func savedOffset() -> NSPoint {
    guard defaults.object(forKey: "offsetX") != nil else { return NSPoint(x: margin, y: margin) }
    return NSPoint(x: defaults.double(forKey: "offsetX"), y: defaults.double(forKey: "offsetY"))
}

var placing = false

func place() {
    guard let screen = targetScreen() else { return }
    let vf = screen.visibleFrame
    let off = savedOffset()
    let x = min(max(vf.maxX - off.x - width, vf.minX), vf.maxX - width)
    let y = min(max(vf.minY + off.y, vf.minY), vf.maxY - height)
    placing = true
    playerPanel.setFrameOrigin(NSPoint(x: x, y: y))
    placing = false
}

final class MoveObserver: NSObject {
    // Keep the position after a drag. A drag can end on a different monitor.
    // Then the offset is clamped at the next place().
    @objc func moved(_ note: Notification) {
        guard !placing, let screen = targetScreen() else { return }
        let vf = screen.visibleFrame
        defaults.set(Double(vf.maxX - playerPanel.frame.maxX), forKey: "offsetX")
        defaults.set(Double(playerPanel.frame.minY - vf.minY), forKey: "offsetY")
    }

    @objc func screensChanged(_ note: Notification) {
        place()
        updateVisibility()
    }

    @objc func command(_ note: Notification) {
        switch note.object as? String {
        case "toggle": defaults.set(!defaults.bool(forKey: "hidden"), forKey: "hidden")
        case "show": defaults.set(false, forKey: "hidden")
        case "hide": defaults.set(true, forKey: "hidden")
        case "reset":
            defaults.removeObject(forKey: "offsetX")
            defaults.removeObject(forKey: "offsetY")
            defaults.set(false, forKey: "hidden")
            place()
        default: return
        }
        updateVisibility()
    }
}

let observer = MoveObserver()
NotificationCenter.default.addObserver(
    observer, selector: #selector(MoveObserver.moved(_:)),
    name: NSWindow.didMoveNotification, object: playerPanel)
NotificationCenter.default.addObserver(
    observer, selector: #selector(MoveObserver.screensChanged(_:)),
    name: NSApplication.didChangeScreenParametersNotification, object: nil)
DistributedNotificationCenter.default().addObserver(
    observer, selector: #selector(MoveObserver.command(_:)),
    name: commandName, object: nil, suspensionBehavior: .deliverImmediately)

// MARK: - Update

// 83 -> "1:23", 3723 -> "1:02:03"
func clock(_ t: Double) -> String {
    let s = max(0, Int(t)), h = s / 3600, m = s / 60 % 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

var failures = 0
var loadedID: String?

func updateVisibility() {
    let show = current != nil && targetScreen() != nil && !defaults.bool(forKey: "hidden")
    if show && !playerPanel.isVisible {
        place()
        playerPanel.orderFrontRegardless()
    } else if !show && playerPanel.isVisible {
        playerPanel.orderOut(nil)
    }
}

func render(_ s: PlayerState) {
    playButton.setSymbol(s.playing ? "pause.fill" : "play.fill")
    likeButton.setSymbol(s.liked ? "heart.fill" : "heart")
    timeLabel.stringValue = s.duration > 0 ? "\(clock(s.progress)) / \(clock(s.duration))" : clock(s.progress)
    let fraction = s.duration > 0 ? min(1, max(0, s.progress / s.duration)) : 0
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.9)
    CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
    barFill.frame = CGRect(x: 0, y: 0, width: barTrack.bounds.width * fraction, height: barHeight)
    CATransaction.commit()
    // The accent color of the track shows when the track has no album art.
    let tint = s.accent.flatMap { background.blended(withFraction: 0.35, of: $0) } ?? background
    root.layer?.backgroundColor = tint.cgColor
    barFill.backgroundColor = (s.accent?.blended(withFraction: 0.45, of: .white) ?? .white).cgColor
    // Dim the art while the track is paused.
    artLayer.opacity = s.playing ? 1 : 0.5
}

// The state gives the track ID but not the title. Read the track info and the
// album art only when the track changes.
func loadTrack(_ id: String) {
    loadedID = id
    call("GET", "/track") { data in
        guard loadedID == id else { return }
        let video = json(data)?["video"] as? [String: Any]
        titleLabel.stringValue = video?["title"] as? String ?? ""
        artistLabel.stringValue = video?["author"] as? String ?? ""
        if video == nil { loadedID = nil }
    }
    call("GET", "/track/thumbnail") { data in
        guard loadedID == id else { return }
        artLayer.contents = data.flatMap { NSImage(data: $0) }
    }
}

// The log records each time the Local API stops or starts to answer. The
// Local API of YTMDesktop2 can stop while the app continues to play. The log
// shows when that happens, so that you can compare it with the system log.
var apiUp: Bool?
var downSince = Date()

func ytmRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: "net.venipa.ytmdesktop").isEmpty
}

func poll() {
    call("GET", "/track/state") { data in
        guard let d = json(data) else {
            // One lost reply does not hide the panel.
            failures += 1
            if failures >= 3 {
                current = nil
                loadedID = nil
                updateVisibility()
                if apiUp != false {
                    downSince = Date()
                    note("API down (\(lastFailure)). The app \(ytmRunning() ? "runs" : "does not run").")
                    apiUp = false
                }
            }
            return
        }
        failures = 0
        if apiUp != true {
            let gap = apiUp == false ? " after \(Int(Date().timeIntervalSince(downSince))) seconds" : ""
            note("API up\(gap).")
            apiUp = true
        }
        current = parseState(d)
        if let s = current {
            if s.id != loadedID { loadTrack(s.id) }
            render(s)
        }
        updateVisibility()
    }
}

Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in poll() }
poll()
app.run()
