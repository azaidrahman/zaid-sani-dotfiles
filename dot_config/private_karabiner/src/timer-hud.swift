import AppKit

// HUD that shows the time left on the macOS Clock.app timers.
//
// Clock.app is not scriptable. The timer daemon keeps its state in a plist, so
// this HUD reads that plist. A running timer holds an absolute fire date. A
// paused timer holds the number of seconds that are left.

let plistPath = ("~/Library/Preferences/com.apple.mobiletimerd.plist" as NSString)
    .expandingTildeInPath

// A borderless window refuses key focus by default. The score HUD reads
// key presses, so it needs a window that accepts them.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// The text HUD reads the return and escape keys through the field editor,
// so a delegate catches them. The digits variant refuses every key that is
// not a digit, which makes bad input impossible at the keystroke.
final class TextModeDelegate: NSObject, NSTextFieldDelegate {
    var digitsOnly = false
    var allowEmpty = false
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let text = control.stringValue.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty || allowEmpty { onSubmit?(text) }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        guard digitsOnly, let field = obj.object as? NSTextField else { return }
        let filtered = field.stringValue.filter { $0.isNumber }
        if filtered != field.stringValue { field.stringValue = filtered }
    }
}

struct TimerInfo {
    let title: String
    let duration: Double
    let remaining: Double
    let running: Bool
}

func readTimers() -> [TimerInfo] {
    guard let data = FileManager.default.contents(atPath: plistPath),
          let root = try? PropertyListSerialization.propertyList(
              from: data, options: [], format: nil) as? [String: Any],
          let outer = root["MTTimers"] as? [String: Any],
          let list = outer["MTTimers"] as? [[String: Any]]
    else { return [] }

    var out: [TimerInfo] = []
    for entry in list {
        guard let t = entry["$MTTimer"] as? [String: Any] else { continue }
        let state = t["MTTimerState"] as? Int ?? 1
        // State 1 means the timer is idle. Only 2 and above are active.
        if state < 2 { continue }

        let duration = t["MTTimerDuration"] as? Double ?? 0
        var remaining: Double? = nil
        var running = false

        // MTTimerFireTime wraps one class dictionary. It holds either an
        // absolute date (the timer runs) or an interval (the timer is paused).
        if let fire = t["MTTimerFireTime"] as? [String: Any] {
            for (_, value) in fire {
                guard let inner = value as? [String: Any] else { continue }
                for (_, field) in inner {
                    if let date = field as? Date {
                        remaining = date.timeIntervalSinceNow
                        running = true
                    } else if let interval = field as? Double, remaining == nil {
                        remaining = interval
                    }
                }
            }
        }

        guard let left = remaining else { continue }
        let title = t["MTTimerTitle"] as? String ?? ""
        out.append(TimerInfo(title: title, duration: duration,
                         remaining: max(0, left), running: running))
    }
    // Show the timer that ends first at the top.
    return out.sorted { $0.remaining < $1.remaining }
}

// The punch tracker writes its state as a naive local datetime, with
// no timezone suffix and optional fractional seconds. ISO8601DateFormatter
// rejects that string, so use a plain DateFormatter instead.
let sessionDateFormatterFrac = DateFormatter()
sessionDateFormatterFrac.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
sessionDateFormatterFrac.timeZone = .current

let sessionDateFormatter = DateFormatter()
sessionDateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
sessionDateFormatter.timeZone = .current

struct SessionInfo {
    let topic: String
    let start: Date
}

// The tracker writes punch.json while a session is open, and renames
// it to punch.ending.json while it closes out. Show the session in
// both cases so the HUD does not blink out right as the session ends.
func readSession() -> SessionInfo? {
    let paths = [
        "~/.local/state/punch.json",
        "~/.local/state/punch.ending.json",
    ]
    for path in paths {
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expanded),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let topic = obj["topic"] as? String,
              let startString = obj["start"] as? String
        else { continue }

        let start = sessionDateFormatterFrac.date(from: startString)
            ?? sessionDateFormatter.date(from: startString)
        guard let start = start else { continue }
        return SessionInfo(topic: topic, start: start)
    }
    return nil
}

func clock(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s >= 3600 {
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
    return String(format: "%d:%02d", s / 60, s % 60)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Pin the appearance. The two Macs run different versions of macOS, and
// macOS 26 changes the default materials, the fonts, and the semantic
// colours. Explicit values keep the HUD identical on both.
NSApp.appearance = NSAppearance(named: .darkAqua)

let hudAccent = NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1.0)

func hudGray(_ white: CGFloat, _ alpha: CGFloat) -> NSColor {
    NSColor(srgbRed: white, green: white, blue: white, alpha: alpha)
}

func hudFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let name = weight == .medium ? "SFProText-Medium" : "SFProText-Regular"
    return NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
}

// A prompt that belongs to a multi-step flow carries a step label. The
// label sits above the prompt in the accent colour, so the user reads the
// position in the flow before the question.
func addStepLabel(_ label: String, to root: NSView,
                  panelWidth: CGFloat, panelHeight: CGFloat) {
    if label.isEmpty { return }
    let view = NSTextField(labelWithString: label)
    view.font = hudFont(ofSize: 11, weight: .medium)
    view.textColor = hudAccent
    view.alignment = .center
    view.lineBreakMode = .byTruncatingTail
    view.frame = NSRect(x: 14, y: panelHeight - 26, width: panelWidth - 28, height: 15)
    root.addSubview(view)
}

// Pill mode: a small floating pill that shows the title of the open punch
// session and the time left in its timebox. The punch tracker starts it when
// a session starts. The pill hides while the hidden flag file exists, and it
// quits when no session is open.
//
//   timer-hud pill
//
if CommandLine.arguments.count >= 2 && CommandLine.arguments[1] == "pill" {
    let stateFiles = [
        "~/.local/state/punch.json",
        "~/.local/state/punch.ending.json",
    ]
    let hiddenFlag = ("~/.local/state/punch-pill.hidden" as NSString)
        .expandingTildeInPath

    // The title is the focus text when the user wrote one, else the topic.
    struct PillSession {
        let title: String
        let plannedEnd: Date
    }

    func readPillSession() -> PillSession? {
        for path in stateFiles {
            let expanded = (path as NSString).expandingTildeInPath
            guard let data = FileManager.default.contents(atPath: expanded),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let topic = obj["topic"] as? String,
                  let endString = obj["planned_end"] as? String
            else { continue }
            guard let end = sessionDateFormatterFrac.date(from: endString)
                    ?? sessionDateFormatter.date(from: endString)
            else { continue }
            let focus = obj["focus"] as? String ?? ""
            return PillSession(title: focus.isEmpty ? topic : focus,
                               plannedEnd: end)
        }
        return nil
    }

    // The pill sits on the notch. A notched screen reports the menu bar on
    // each side of the notch as an auxiliary area, so the notch is the gap
    // between the two areas. A screen with no notch gets a simulated notch of
    // the same kind at the top centre. The wings are the black areas that
    // extend the notch on each side, and they hold the title and the timer.
    let simulatedNotchWidth: CGFloat = 200
    let simulatedNotchHeight: CGFloat = 32
    let wingWidth: CGFloat = 120

    let pillView = NSView(frame: .zero)
    pillView.wantsLayer = true
    // The wings are see-through, so they hide less of the menu bar. On a
    // notch screen the notch itself stays black, because it is hardware.
    pillView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
    // Only the bottom corners are round, so the top edge meets the screen edge.
    pillView.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]

    // The title sits in the left wing and the timer in the right wing.
    let titleLabel = NSTextField(labelWithString: "")
    titleLabel.font = hudFont(ofSize: 12, weight: .medium)
    titleLabel.textColor = hudGray(1, 0.95)
    titleLabel.lineBreakMode = .byTruncatingTail

    let timerLabel = NSTextField(labelWithString: "")
    timerLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    timerLabel.textColor = hudAccent
    timerLabel.alignment = .right

    pillView.addSubview(titleLabel)
    pillView.addSubview(timerLabel)

    // Above the menu bar, so the pill covers the notch. The level is the one
    // that the notch apps use. It ignores the mouse, so a click on the menu
    // bar beside it still reaches the menu bar.
    let pillPanel = NSPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    pillPanel.isOpaque = false
    pillPanel.backgroundColor = .clear
    pillPanel.level = .mainMenu + 3
    pillPanel.hasShadow = false
    pillPanel.ignoresMouseEvents = true
    pillPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
    pillPanel.contentView = pillView
    pillPanel.appearance = NSAppearance(named: .darkAqua)

    // Place the pill on the notch of the current screens. The screens change
    // when the user docks or undocks, so this runs again on each change. A
    // pill that kept its first frame would sit off screen after an undock.
    func place() {
        // The notch screen comes first, so the pill follows the built-in
        // display. The first screen is the one with the menu bar, which is
        // the fallback.
        let notchScreen = NSScreen.screens.first {
            $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil
        }
        let screen = notchScreen ?? NSScreen.screens.first
        let sf = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var notchLeft = sf.midX - simulatedNotchWidth / 2
        var notchRight = sf.midX + simulatedNotchWidth / 2
        var pillHeight = simulatedNotchHeight
        if let s = notchScreen,
           let leftArea = s.auxiliaryTopLeftArea,
           let rightArea = s.auxiliaryTopRightArea {
            notchLeft = leftArea.maxX
            notchRight = rightArea.minX
            // The safe area top is the height of the notch itself.
            pillHeight = max(s.safeAreaInsets.top, 24)
        }
        let pillWidth = (notchRight - notchLeft) + wingWidth * 2
        let labelY = (pillHeight - 17) / 2

        pillView.frame = NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight)
        pillView.layer?.cornerRadius = pillHeight / 2
        titleLabel.frame = NSRect(x: 12, y: labelY, width: wingWidth - 24, height: 17)
        timerLabel.frame = NSRect(x: pillWidth - wingWidth + 12, y: labelY,
                                  width: wingWidth - 24, height: 17)
        pillPanel.setFrame(NSRect(x: notchLeft - wingWidth, y: sf.maxY - pillHeight,
                                  width: pillWidth, height: pillHeight),
                           display: true)
    }

    func refresh() {
        guard let session = readPillSession() else {
            app.terminate(nil)
            return
        }
        titleLabel.stringValue = session.title
        // Past the timebox the pill counts up with a plus sign, so an
        // overrun stays visible instead of freezing at zero.
        let left = session.plannedEnd.timeIntervalSinceNow
        timerLabel.stringValue = left >= 0 ? clock(left) : "+" + clock(-left)

        if FileManager.default.fileExists(atPath: hiddenFlag) {
            pillPanel.orderOut(nil)
        } else {
            pillPanel.orderFrontRegardless()
        }
    }

    place()
    refresh()

    NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification,
        object: nil, queue: .main) { _ in place() }

    let pillTicker = Foundation.Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        refresh()
    }
    RunLoop.main.add(pillTicker, forMode: .common)

    app.run()
    exit(0)
}

// Toast mode: a short bottom-center message, no timer plist, no ticker.
// The punch tracker uses this because Notification Center drops
// its notifications on this machine.
if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "toast" {
    let text = CommandLine.arguments[2]

    let maxWidth: CGFloat = 420
    let padding: CGFloat = 16
    let font = hudFont(ofSize: 15, weight: .medium)

    let label = NSTextField(labelWithString: text)
    label.font = font
    label.textColor = hudGray(1, 1)
    label.alignment = .center
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0

    // Measure the text so the toast hugs it, wrapping only past maxWidth.
    let attrs = [NSAttributedString.Key.font: font]
    let unwrapped = (text as NSString).size(withAttributes: attrs)
    let textWidth = min(unwrapped.width, maxWidth - padding * 2)
    let boundingBox = (text as NSString).boundingRect(
        with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin],
        attributes: attrs)

    let toastWidth = ceil(boundingBox.width) + padding * 2
    let toastHeight = ceil(boundingBox.height) + padding * 2

    let toastView = NSView(frame: NSRect(x: 0, y: 0, width: toastWidth, height: toastHeight))
    toastView.wantsLayer = true
    toastView.layer?.backgroundColor = hudGray(0.1, 0.9).cgColor
    toastView.layer?.cornerRadius = 14
    label.frame = NSRect(x: padding, y: padding, width: toastWidth - padding * 2,
                          height: toastHeight - padding * 2)
    toastView.addSubview(label)

    let toastPanel = NSPanel(
        contentRect: toastView.frame,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    toastPanel.isOpaque = false
    toastPanel.backgroundColor = .clear
    toastPanel.level = .floating
    toastPanel.hasShadow = false
    toastPanel.contentView = toastView
    toastPanel.appearance = NSAppearance(named: .darkAqua)

    if let screen = NSScreen.main {
        let sf = screen.frame
        toastPanel.setFrameOrigin(NSPoint(
            x: sf.midX - toastWidth / 2,
            y: sf.minY + 120))
    }

    toastPanel.orderFront(nil)

    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        app.terminate(nil)
    }

    app.run()
    exit(0)
}

// Score mode: ask how distracted the session was. One key press answers,
// so the user never reaches for the mouse. The HUD prints the score, the
// word skip, or the word timeout, and the caller decides what each means.
//
//   timer-hud score "<topic>" [<seconds>]
//
if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "score" {
    let topic = CommandLine.arguments[2]
    let timeout = CommandLine.arguments.count >= 4
        ? (Double(CommandLine.arguments[3]) ?? 180) : 180

    // Hold the app that had focus. The HUD takes focus to read the keys,
    // so it must give the focus back when it closes.
    let previous = NSWorkspace.shared.frontmostApplication

    func finish(_ answer: String) {
        print(answer)
        fflush(stdout)
        previous?.activate(options: [])
        exit(0)
    }

    let panelWidth: CGFloat = 470
    let panelHeight: CGFloat = 158

    let root = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
    root.wantsLayer = true
    root.layer?.backgroundColor = hudGray(0.1, 0.95).cgColor
    root.layer?.cornerRadius = 14

    func line(_ text: String, size: CGFloat, weight: NSFont.Weight,
              alpha: CGFloat, y: CGFloat, height: CGFloat) {
        let label = NSTextField(labelWithString: text)
        label.font = hudFont(ofSize: size, weight: weight)
        label.textColor = hudGray(1, alpha)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 12, y: y, width: panelWidth - 24, height: height)
        root.addSubview(label)
    }

    line("How distracted were you?", size: 15, weight: .medium,
         alpha: 1, y: panelHeight - 36, height: 20)
    line(topic, size: 12, weight: .regular,
         alpha: 0.55, y: panelHeight - 56, height: 16)

    // One chip for each score. The 0 key stands for ten, because no key
    // holds two digits.
    let chip: CGFloat = 36
    let gap: CGFloat = 7
    let rowWidth = chip * 10 + gap * 9
    var chips: [NSView] = []
    for i in 0..<10 {
        let x = (panelWidth - rowWidth) / 2 + CGFloat(i) * (chip + gap)
        let box = NSView(frame: NSRect(x: x, y: 52, width: chip, height: chip))
        box.wantsLayer = true
        box.layer?.backgroundColor = hudGray(1, 0.10).cgColor
        box.layer?.cornerRadius = 9
        let label = NSTextField(labelWithString: i == 9 ? "0" : "\(i + 1)")
        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        label.textColor = hudGray(1, 1)
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 8, width: chip, height: 20)
        box.addSubview(label)
        root.addSubview(box)
        chips.append(box)
    }

    line("1 is no interruptions · 10 is never more than 15 clear minutes",
         size: 11, weight: .regular, alpha: 0.5, y: 28, height: 15)
    line("press a number · 0 is ten · esc skips",
         size: 11, weight: .regular, alpha: 0.35, y: 10, height: 15)

    let panel = KeyPanel(
        contentRect: root.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .floating
    panel.hasShadow = true
    panel.contentView = root
    panel.appearance = NSAppearance(named: .darkAqua)

    if let screen = NSScreen.main {
        let sf = screen.frame
        panel.setFrameOrigin(NSPoint(x: sf.midX - panelWidth / 2,
                                     y: sf.midY - panelHeight / 2))
    }

    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        // 53 is the escape key.
        if event.keyCode == 53 {
            finish("skip")
        }
        guard let chars = event.charactersIgnoringModifiers,
              chars.count == 1, let digit = Int(chars)
        else { return nil }

        let score = digit == 0 ? 10 : digit
        // Light the chip, so the user sees which key the HUD read.
        chips[score - 1].layer?.backgroundColor = hudAccent.cgColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            finish("\(score)")
        }
        return nil
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
        finish("timeout")
    }

    panel.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    app.run()
    exit(0)
}

// Text mode: one line of free text. The return key confirms and prints the
// text. Escape and the timeout print nothing and exit 2, because a topic
// named "skip" must stay expressible. The digits variant accepts digit
// keys only and refuses an empty confirm.
//
//   timer-hud text [--step "<label>"] [--allow-empty] "<prompt>" ["<placeholder>"]
//   timer-hud digits [--step "<label>"] "<prompt>" ["<placeholder>"]
//
// With --allow-empty, the return key on a blank line prints an empty line.
//
if CommandLine.arguments.count >= 3 &&
   (CommandLine.arguments[1] == "text" || CommandLine.arguments[1] == "digits") {
    // --step comes before the prompt. It names the step of a multi-step
    // flow, so the user always sees where the prompt sits in the flow.
    var argIndex = 2
    var stepLabel = ""
    // --allow-empty lets the return key confirm a blank line. The caller
    // uses it for an answer that is optional.
    var allowEmpty = false
    flags: while argIndex < CommandLine.arguments.count {
        switch CommandLine.arguments[argIndex] {
        case "--step" where argIndex + 1 < CommandLine.arguments.count:
            stepLabel = CommandLine.arguments[argIndex + 1]
            argIndex += 2
        case "--allow-empty":
            allowEmpty = true
            argIndex += 1
        default:
            break flags
        }
    }
    guard argIndex < CommandLine.arguments.count else { exit(2) }
    let prompt = CommandLine.arguments[argIndex]
    let placeholder = CommandLine.arguments.count > argIndex + 1
        ? CommandLine.arguments[argIndex + 1] : ""

    let previous = NSWorkspace.shared.frontmostApplication

    func finish(_ answer: String?, code: Int32) -> Never {
        if let answer = answer { print(answer); fflush(stdout) }
        previous?.activate(options: [])
        exit(code)
    }

    let panelWidth: CGFloat = 470
    let panelHeight: CGFloat = stepLabel.isEmpty ? 118 : 138

    let root = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
    root.wantsLayer = true
    root.layer?.backgroundColor = hudGray(0.1, 0.95).cgColor
    root.layer?.cornerRadius = 14

    addStepLabel(stepLabel, to: root, panelWidth: panelWidth, panelHeight: panelHeight)

    let head = NSTextField(labelWithString: prompt)
    head.font = hudFont(ofSize: 15, weight: .medium)
    head.textColor = hudGray(1, 1)
    head.alignment = .center
    head.frame = NSRect(x: 14, y: panelHeight - (stepLabel.isEmpty ? 34 : 54),
                        width: panelWidth - 28, height: 20)
    root.addSubview(head)

    let field = NSTextField(frame: NSRect(x: 24, y: 44, width: panelWidth - 48, height: 28))
    field.font = hudFont(ofSize: 14, weight: .regular)
    field.placeholderString = placeholder
    field.wantsLayer = true
    field.layer?.cornerRadius = 8
    field.focusRingType = .none
    field.bezelStyle = .roundedBezel
    root.addSubview(field)

    let hint = NSTextField(labelWithString: stepLabel.isEmpty
        ? "⏎ confirms · esc cancels"
        : "⏎ confirms · esc goes back")
    hint.font = hudFont(ofSize: 11, weight: .regular)
    hint.textColor = hudGray(1, 0.35)
    hint.alignment = .center
    hint.frame = NSRect(x: 14, y: 12, width: panelWidth - 28, height: 15)
    root.addSubview(hint)

    let delegate = TextModeDelegate()
    delegate.digitsOnly = CommandLine.arguments[1] == "digits"
    delegate.allowEmpty = allowEmpty
    delegate.onSubmit = { text in finish(text, code: 0) }
    delegate.onCancel = { finish(nil, code: 2) }
    field.delegate = delegate

    let panel = KeyPanel(
        contentRect: root.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .floating
    panel.hasShadow = true
    panel.contentView = root
    panel.appearance = NSAppearance(named: .darkAqua)

    if let screen = NSScreen.main {
        let sf = screen.frame
        panel.setFrameOrigin(NSPoint(x: sf.midX - panelWidth / 2,
                                     y: sf.midY - panelHeight / 2))
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
        finish(nil, code: 2)
    }

    // NSTextField.delegate is a weak reference. Without this, ARC can free
    // the local delegate right after field.delegate is set, so Return,
    // Escape, and the digit filter would silently stop working and only
    // the 180s timeout would ever fire.
    withExtendedLifetime(delegate) {
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
    exit(0)
}

// Time mode: three fields — hour, minute, am/pm — for a start time today.
// Tab and the left/right arrows move between the fields. Digits type into
// the current field, and two digits move on. Up and down adjust the
// focused field: the hour cycles 1-12, the minute wraps 0-59, and the
// am/pm field flips. The a and p keys set am/pm from any field. Return
// confirms. A future time flashes and stays open, because a retroactive
// start must lie in the past. Escape and the timeout exit 2 with no output.
//
//   timer-hud time [--step "<label>"] "<prompt>" <hh> <mm> <am|pm> <timebox>
//
// The a and p keys already set am/pm here, so p cannot mean "previous
// step". Escape leaves the prompt, and the caller decides whether that is
// a step backwards or a cancel.
if CommandLine.arguments.count >= 7 && CommandLine.arguments[1] == "time" {
    var argIndex = 2
    var stepLabel = ""
    while argIndex + 1 < CommandLine.arguments.count,
          CommandLine.arguments[argIndex] == "--step" {
        stepLabel = CommandLine.arguments[argIndex + 1]
        argIndex += 2
    }
    guard argIndex + 4 < CommandLine.arguments.count else { exit(2) }
    let prompt = CommandLine.arguments[argIndex]
    var hour = min(12, max(1, Int(CommandLine.arguments[argIndex + 1]) ?? 9))
    var minute = min(59, max(0, Int(CommandLine.arguments[argIndex + 2]) ?? 0))
    var isPM = CommandLine.arguments[argIndex + 3].lowercased() == "pm"
    let timebox = max(1, Int(CommandLine.arguments[argIndex + 4]) ?? 25)

    let previous = NSWorkspace.shared.frontmostApplication

    func finish(_ answer: String?, code: Int32) -> Never {
        if let answer = answer { print(answer); fflush(stdout) }
        previous?.activate(options: [])
        exit(code)
    }

    var field = 0      // 0 hour, 1 minute, 2 am/pm
    var typed = ""     // digits typed into the current field

    func hour24() -> Int {
        var h = hour % 12
        if isPM { h += 12 }
        return h
    }

    func startDate() -> Date {
        Calendar.current.date(bySettingHour: hour24(), minute: minute,
                              second: 0, of: Date()) ?? Date()
    }

    let panelWidth: CGFloat = 470
    let panelHeight: CGFloat = stepLabel.isEmpty ? 190 : 210

    let root = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
    root.wantsLayer = true
    root.layer?.backgroundColor = hudGray(0.1, 0.95).cgColor
    root.layer?.cornerRadius = 14

    addStepLabel(stepLabel, to: root, panelWidth: panelWidth, panelHeight: panelHeight)

    let head = NSTextField(labelWithString: prompt)
    head.font = hudFont(ofSize: 15, weight: .medium)
    head.textColor = hudGray(1, 1)
    head.alignment = .center
    head.frame = NSRect(x: 14, y: panelHeight - (stepLabel.isEmpty ? 34 : 54),
                        width: panelWidth - 28, height: 20)
    root.addSubview(head)

    // Three boxes: hour, minute, am/pm. The colon sits between the first two.
    let boxWidth: CGFloat = 64
    let boxHeight: CGFloat = 44
    let gap: CGFloat = 26
    let rowWidth = boxWidth * 3 + gap * 2
    let rowX = (panelWidth - rowWidth) / 2
    let rowY: CGFloat = 92

    var boxes: [NSView] = []
    var values: [NSTextField] = []
    for i in 0..<3 {
        let x = rowX + CGFloat(i) * (boxWidth + gap)
        let box = NSView(frame: NSRect(x: x, y: rowY, width: boxWidth, height: boxHeight))
        box.wantsLayer = true
        box.layer?.cornerRadius = 9
        let value = NSTextField(labelWithString: "")
        value.font = .monospacedDigitSystemFont(ofSize: 20, weight: .medium)
        value.textColor = hudGray(1, 1)
        value.alignment = .center
        value.frame = NSRect(x: 0, y: 11, width: boxWidth, height: 24)
        box.addSubview(value)
        root.addSubview(box)
        boxes.append(box)
        values.append(value)
    }

    let colon = NSTextField(labelWithString: ":")
    colon.font = .monospacedDigitSystemFont(ofSize: 20, weight: .medium)
    colon.textColor = hudGray(1, 0.6)
    colon.alignment = .center
    colon.frame = NSRect(x: rowX + boxWidth, y: rowY + 11, width: gap, height: 24)
    root.addSubview(colon)

    let names = NSTextField(labelWithString: "hour · minute · am/pm")
    names.font = hudFont(ofSize: 11, weight: .regular)
    names.textColor = hudGray(1, 0.5)
    names.alignment = .center
    names.frame = NSRect(x: 14, y: rowY - 22, width: panelWidth - 28, height: 15)
    root.addSubview(names)

    let preview = NSTextField(labelWithString: "")
    preview.font = hudFont(ofSize: 12, weight: .regular)
    preview.textColor = hudGray(1, 0.6)
    preview.alignment = .center
    preview.frame = NSRect(x: 14, y: 34, width: panelWidth - 28, height: 16)
    root.addSubview(preview)

    let hint = NSTextField(labelWithString: stepLabel.isEmpty
        ? "arrows move and adjust · digits type · a/p set · ⏎ confirms · esc cancels"
        : "arrows move and adjust · digits type · a/p set · ⏎ confirms · esc goes back")
    hint.font = hudFont(ofSize: 11, weight: .regular)
    hint.textColor = hudGray(1, 0.35)
    hint.alignment = .center
    hint.frame = NSRect(x: 14, y: 12, width: panelWidth - 28, height: 15)
    root.addSubview(hint)

    let endFormatter = DateFormatter()
    endFormatter.dateFormat = "HH:mm"

    func render() {
        values[0].stringValue = String(format: "%02d", hour)
        values[1].stringValue = String(format: "%02d", minute)
        values[2].stringValue = isPM ? "PM" : "AM"
        for i in 0..<3 {
            boxes[i].layer?.backgroundColor = i == field
                ? hudAccent.withAlphaComponent(0.35).cgColor
                : hudGray(1, 0.10).cgColor
        }
        // The preview shows which branch the entry takes: a block that
        // already ended is a retro session, the rest stays live.
        let end = startDate().addingTimeInterval(Double(timebox) * 60)
        let left = end.timeIntervalSinceNow
        let branch = left > 60 ? "\(Int(left / 60)) min left" : "already finished"
        preview.stringValue = "ends \(endFormatter.string(from: end)) · \(timebox) min · \(branch)"
    }

    func flash() {
        // A future start is refused. Flash the boxes so the user sees why
        // the return key did nothing.
        let red = NSColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 0.5)
        for box in boxes { box.layer?.backgroundColor = red.cgColor }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { render() }
    }

    func advance() {
        typed = ""
        field = (field + 1) % 3
        render()
    }

    render()

    let panel = KeyPanel(
        contentRect: root.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .floating
    panel.hasShadow = true
    panel.contentView = root
    panel.appearance = NSAppearance(named: .darkAqua)

    if let screen = NSScreen.main {
        let sf = screen.frame
        panel.setFrameOrigin(NSPoint(x: sf.midX - panelWidth / 2,
                                     y: sf.midY - panelHeight / 2))
    }

    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        // 53 esc, 48 tab, 36 return, 123 left, 124 right, 125 down, 126 up.
        if event.keyCode == 53 { finish(nil, code: 2) }
        if event.keyCode == 48 { advance(); return nil }
        if event.keyCode == 124 { advance(); return nil }
        if event.keyCode == 123 {
            typed = ""
            field = (field + 2) % 3
            render()
            return nil
        }
        if event.keyCode == 125 || event.keyCode == 126 {
            // Arrows adjust the focused field instead of always flipping
            // am/pm. A half-typed digit is cleared first so it cannot
            // linger and get folded into the next keystroke.
            typed = ""
            let up = event.keyCode == 126
            if field == 0 {
                hour = up ? hour % 12 + 1 : (hour == 1 ? 12 : hour - 1)
            } else if field == 1 {
                minute = up ? (minute + 1) % 60 : (minute + 59) % 60
            } else {
                isPM = !isPM
            }
            render()
            return nil
        }
        if event.keyCode == 36 {
            if startDate() > Date() {
                flash()
            } else {
                finish(String(format: "%02d:%02d", hour24(), minute), code: 0)
            }
            return nil
        }

        let chars = event.charactersIgnoringModifiers ?? ""
        if chars == "a" { isPM = false; render(); return nil }
        if chars == "p" { isPM = true; render(); return nil }

        guard chars.count == 1, let digit = Int(chars) else { return nil }

        typed += "\(digit)"
        if field == 0 {
            // The hour reads 1-12. A first digit of 2-9 is a full hour. A
            // 1 waits for a second digit, and 10-12 land as two digits.
            let v = Int(typed) ?? 0
            if typed.count == 2 {
                hour = (1...12).contains(v) ? v : digit == 0 ? 10 : digit
                advance()
            } else if v >= 2 {
                hour = v
                advance()
            } else {
                render()
            }
        } else if field == 1 {
            // The minute reads 0-59. A first digit of 6-9 is a full minute.
            let v = Int(typed) ?? 0
            if typed.count == 2 {
                minute = min(59, v)
                advance()
            } else if v >= 6 {
                minute = v
                advance()
            } else {
                minute = v
                render()
            }
        }
        return nil
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
        finish(nil, code: 2)
    }

    panel.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    app.run()
    exit(0)
}

// Pick mode: choose one item from a list with one key press. The list
// shows 5 items at a time. The bracket keys turn the page. The HUD prints
// the index of the item, the word skip, the word back, or the word
// timeout.
//
//   timer-hud pick [--select <n>] [--step "<label>"] [--back] [--search] \
//       [--ctrl-key <char>=<token>] "<prompt>" "<item>" "<item>" ...
//
// --step names the step of a multi-step flow and turns on the n key,
// which takes the highlighted item. --back turns on the p key, which
// prints back and lets the caller show the step before this one.
// --search turns on a fuzzy search: the letter keys type a query that
// narrows the list, and the delete key erases it. The digit keys still
// pick a visible row, so a search plus one digit takes an item. The
// letter keys type in this mode, so the n and the p keys stay off.
// --ctrl-key gives the pick one more answer: control and the character
// print the token and end the pick. The search reads no key that holds
// control, so the two never collide.
if CommandLine.arguments.count >= 4 && CommandLine.arguments[1] == "pick" {
    var argIndex = 2
    var selected = 0
    var stepLabel = ""
    var canGoBack = false
    var canSearch = false
    var ctrlChar = ""
    var ctrlToken = ""
    flags: while argIndex < CommandLine.arguments.count {
        switch CommandLine.arguments[argIndex] {
        case "--select" where argIndex + 1 < CommandLine.arguments.count:
            selected = Int(CommandLine.arguments[argIndex + 1]) ?? 0
            argIndex += 2
        case "--step" where argIndex + 1 < CommandLine.arguments.count:
            stepLabel = CommandLine.arguments[argIndex + 1]
            argIndex += 2
        case "--back":
            canGoBack = true
            argIndex += 1
        case "--search":
            canSearch = true
            argIndex += 1
        case "--ctrl-key" where argIndex + 1 < CommandLine.arguments.count:
            let parts = CommandLine.arguments[argIndex + 1]
                .split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                ctrlChar = String(parts[0]).lowercased()
                ctrlToken = String(parts[1])
            }
            argIndex += 2
        default:
            break flags
        }
    }
    guard argIndex + 1 < CommandLine.arguments.count else { exit(2) }
    let prompt = CommandLine.arguments[argIndex]
    let items = Array(CommandLine.arguments.dropFirst(argIndex + 1))
    if selected < 0 || selected >= items.count { selected = 0 }

    let previous = NSWorkspace.shared.frontmostApplication

    func finish(_ answer: String) {
        print(answer)
        fflush(stdout)
        previous?.activate(options: [])
        exit(0)
    }

    let perPage = 5
    let visible = min(perPage, items.count)

    // The search narrows the list to `filtered`, which holds indexes into
    // `items`. With no query every item is in it, so a pick with no
    // --search runs on the same model. `selected` is a position in
    // `filtered`, and the HUD prints the item index that the position
    // holds.
    var query = ""
    var filtered = Array(items.indices)
    var pages = (filtered.count + perPage - 1) / perPage
    var page = selected / perPage

    // Return how well the query matches one item, or nil for no match.
    // A lower rank sorts first: 0 is a prefix, 1 is a substring, and 2 is
    // a subsequence, so "ku" puts "Kubernetes" above "Haiku".
    func matchRank(_ item: String) -> Int? {
        if query.isEmpty { return 0 }
        let hay = item.lowercased()
        let needle = query.lowercased()
        if hay.hasPrefix(needle) { return 0 }
        if hay.contains(needle) { return 1 }
        var next = needle.startIndex
        for ch in hay {
            if ch == needle[next] {
                next = needle.index(after: next)
                if next == needle.endIndex { return 2 }
            }
        }
        return nil
    }

    let panelWidth: CGFloat = 480
    let rowHeight: CGFloat = 32
    let searchArea: CGFloat = canSearch ? 24 : 0
    let headArea: CGFloat = (stepLabel.isEmpty ? 42 : 62) + searchArea
    let footArea: CGFloat = 34
    let panelHeight = headArea + rowHeight * CGFloat(visible) + footArea

    let root = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
    root.wantsLayer = true
    root.layer?.backgroundColor = hudGray(0.1, 0.95).cgColor
    root.layer?.cornerRadius = 14

    addStepLabel(stepLabel, to: root, panelWidth: panelWidth, panelHeight: panelHeight)

    let head = NSTextField(labelWithString: prompt)
    head.font = hudFont(ofSize: 15, weight: .medium)
    head.textColor = hudGray(1, 1)
    head.alignment = .center
    head.lineBreakMode = .byTruncatingTail
    head.frame = NSRect(x: 14, y: panelHeight - (stepLabel.isEmpty ? 32 : 52),
                        width: panelWidth - 28, height: 20)
    root.addSubview(head)

    // The query sits under the prompt, so the user reads what the HUD
    // searched for. An empty query shows a hint in its place.
    let queryLabel = NSTextField(labelWithString: "")
    queryLabel.font = hudFont(ofSize: 13, weight: .regular)
    queryLabel.alignment = .center
    queryLabel.lineBreakMode = .byTruncatingTail
    queryLabel.frame = NSRect(x: 14,
                              y: panelHeight - (stepLabel.isEmpty ? 54 : 74),
                              width: panelWidth - 28, height: 18)
    if canSearch { root.addSubview(queryLabel) }

    var rows: [NSView] = []
    var numbers: [NSTextField] = []
    var labels: [NSTextField] = []

    for i in 0..<visible {
        let y = footArea + rowHeight * CGFloat(visible - 1 - i)
        let row = NSView(frame: NSRect(x: 14, y: y, width: panelWidth - 28, height: rowHeight - 4))
        row.wantsLayer = true
        row.layer?.backgroundColor = hudGray(1, 0.07).cgColor
        row.layer?.cornerRadius = 8

        let num = NSTextField(labelWithString: "\(i + 1)")
        num.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        num.textColor = hudGray(1, 0.65)
        num.alignment = .center
        num.frame = NSRect(x: 6, y: 5, width: 20, height: 18)
        row.addSubview(num)

        let label = NSTextField(labelWithString: "")
        label.font = hudFont(ofSize: 13, weight: .regular)
        label.textColor = hudGray(1, 1)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 34, y: 5, width: panelWidth - 28 - 44, height: 18)
        row.addSubview(label)

        root.addSubview(row)
        rows.append(row)
        numbers.append(num)
        labels.append(label)
    }

    let foot = NSTextField(labelWithString: "")
    foot.font = hudFont(ofSize: 11, weight: .regular)
    foot.textColor = hudGray(1, 0.35)
    foot.alignment = .center
    foot.frame = NSRect(x: 14, y: 10, width: panelWidth - 28, height: 15)
    root.addSubview(foot)

    func render() {
        if canSearch {
            queryLabel.stringValue = query.isEmpty
                ? "type to search" : "⌕ \(query)"
            queryLabel.textColor = query.isEmpty
                ? hudGray(1, 0.35) : hudAccent
        }
        for i in 0..<visible {
            let position = page * perPage + i
            let present = position < filtered.count
            rows[i].isHidden = !present
            if present { labels[i].stringValue = items[filtered[position]] }
            let isSelected = present && position == selected
            rows[i].layer?.backgroundColor = isSelected
                ? hudAccent.withAlphaComponent(0.35).cgColor
                : hudGray(1, 0.07).cgColor
        }
        let shown = min(visible, filtered.count - page * perPage)
        var hint = "↑↓ move · ⏎ take · 1-\(max(1, shown)) jumps · esc cancels"
        if filtered.isEmpty {
            hint = "no match · ⌫ deletes · esc cancels"
        } else if pages > 1 {
            hint = "↑↓ move · ⏎ take · 1-\(max(1, shown)) · [ ] page \(page + 1)/\(pages) · esc"
        }
        if !stepLabel.isEmpty && !canSearch {
            hint += canGoBack ? " · n next · p back" : " · n next"
        }
        if !ctrlChar.isEmpty {
            hint += " · ⌃\(ctrlChar) \(ctrlToken)"
        }
        foot.stringValue = hint
    }

    // Narrow the list to the items that match the query, best match
    // first. The highlight goes to the top, so a search plus return
    // takes the best match.
    func refilter() {
        let ranked = items.indices.compactMap { i in
            matchRank(items[i]).map { (index: i, rank: $0) }
        }
        filtered = ranked
            .sorted { $0.rank == $1.rank ? $0.index < $1.index : $0.rank < $1.rank }
            .map { $0.index }
        pages = (filtered.count + perPage - 1) / perPage
        selected = 0
        page = 0
        render()
    }

    // The highlighted item is the answer. The flash marks the choice, so
    // the user sees which row the HUD took.
    func take() {
        guard selected < filtered.count else { return }
        let row = selected % perPage
        rows[row].layer?.backgroundColor = hudAccent.cgColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            finish("\(filtered[selected])")
        }
    }

    render()

    let panel = KeyPanel(
        contentRect: root.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .floating
    panel.hasShadow = true
    panel.contentView = root
    panel.appearance = NSAppearance(named: .darkAqua)

    if let screen = NSScreen.main {
        let sf = screen.frame
        panel.setFrameOrigin(NSPoint(x: sf.midX - panelWidth / 2,
                                     y: sf.midY - panelHeight / 2))
    }

    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        // 53 is escape, 51 is delete, 123 is the left arrow, 124 is the
        // right arrow, 125 is the down arrow, 126 is the up arrow, 36 is
        // return.
        if event.keyCode == 53 {
            finish("skip")
        }
        let chars = event.charactersIgnoringModifiers ?? ""

        // Control and the character end the pick with the token. This
        // comes first, so no later key reads the same press.
        if !ctrlChar.isEmpty && event.modifierFlags.contains(.control)
            && chars.lowercased() == ctrlChar {
            finish(ctrlToken)
            return nil
        }

        // n takes the highlighted item and p leaves for the step before
        // this one. Both keys work only in a multi-step flow with no
        // search, because a search needs every letter for the query.
        if !stepLabel.isEmpty && !canSearch {
            if chars == "n" { take(); return nil }
            if chars == "p" && canGoBack { finish("back") }
        }

        if canSearch && event.keyCode == 51 {
            if !query.isEmpty { query.removeLast(); refilter() }
            return nil
        }

        if event.keyCode == 125 {
            if selected < filtered.count - 1 { selected += 1; page = selected / perPage; render() }
            return nil
        }
        if event.keyCode == 126 {
            if selected > 0 { selected -= 1; page = selected / perPage; render() }
            return nil
        }
        if event.keyCode == 36 {
            take()
            return nil
        }

        if chars == "[" || event.keyCode == 123 {
            if page > 0 { page -= 1; selected = page * perPage; render() }
            return nil
        }
        if chars == "]" || event.keyCode == 124 {
            if page < pages - 1 { page += 1; selected = page * perPage; render() }
            return nil
        }

        if let digit = Int(chars), chars.count == 1,
           digit >= 1, digit <= visible {
            let position = page * perPage + (digit - 1)
            guard position < filtered.count else { return nil }

            selected = position
            rows[digit - 1].layer?.backgroundColor = hudAccent.cgColor
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                finish("\(filtered[position])")
            }
            return nil
        }

        // Every other printable key types into the query. The digit keys
        // stay pickers, so a search plus one digit takes an item.
        if canSearch, chars.count == 1,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let ch = chars.first, !ch.isNewline,
           ch.isLetter || ch.isNumber || ch.isWhitespace
               || ch.isPunctuation || ch.isSymbol {
            query.append(ch)
            refilter()
            return nil
        }
        return nil
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
        finish("timeout")
    }

    panel.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    app.run()
    exit(0)
}

let width: CGFloat = 250
let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 90))
view.wantsLayer = true
view.layer?.backgroundColor = hudGray(0.1, 0.9).cgColor
view.layer?.cornerRadius = 14

let bigLabel = NSTextField(labelWithString: "")
bigLabel.font = .monospacedDigitSystemFont(ofSize: 28, weight: .medium)
bigLabel.textColor = hudGray(1, 1)
bigLabel.alignment = .center

let subLabel = NSTextField(labelWithString: "")
subLabel.font = hudFont(ofSize: 13, weight: .regular)
subLabel.textColor = hudGray(1, 0.6)
subLabel.alignment = .center

let extraLabel = NSTextField(labelWithString: "")
extraLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
extraLabel.textColor = hudGray(1, 0.6)
extraLabel.alignment = .center

view.addSubview(bigLabel)
view.addSubview(subLabel)
view.addSubview(extraLabel)

let w = NSPanel(
    contentRect: view.frame,
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
w.isOpaque = false
w.backgroundColor = .clear
w.level = .floating
w.hasShadow = true
w.contentView = view
w.appearance = NSAppearance(named: .darkAqua)

func layout(height: CGFloat) {
    view.frame = NSRect(x: 0, y: 0, width: width, height: height)
    bigLabel.frame = NSRect(x: 0, y: height - 46, width: width, height: 36)
    subLabel.frame = NSRect(x: 0, y: height - 68, width: width, height: 18)
    extraLabel.frame = NSRect(x: 0, y: 6, width: width, height: 18)
    w.setContentSize(view.frame.size)
    if let screen = NSScreen.main {
        let sf = screen.frame
        w.setFrameOrigin(NSPoint(x: sf.midX - width / 2, y: sf.midY - height / 2))
    }
}

func refresh() {
    let timers = readTimers()
    guard let first = timers.first else {
        bigLabel.stringValue = "No timer"
        if let session = readSession() {
            let elapsed = clock(max(0, Date().timeIntervalSince(session.start)))
            subLabel.stringValue = "\(session.topic) — \(elapsed) elapsed"
        } else {
            subLabel.stringValue = "Clock.app has no active timer"
        }
        extraLabel.stringValue = ""
        layout(height: 74)
        return
    }

    bigLabel.stringValue = clock(first.remaining)
    var sub = first.running ? "left" : "paused"
    if first.duration > 0 { sub += " of \(clock(first.duration))" }
    if !first.title.isEmpty { sub = "\(first.title) — \(sub)" }
    subLabel.stringValue = sub

    // The punch session may still be open while a Clock.app timer runs, so
    // show the topic here too. This is the primary case: the macro starts a
    // timer, and the user checks the HUD while the session is active.
    if let s = readSession() {
        subLabel.stringValue = "\(s.topic) — \(clock(max(0, Date().timeIntervalSince(s.start)))) elapsed"
    }

    // List any other active timers on one line.
    let rest = timers.dropFirst().map { clock($0.remaining) }
    extraLabel.stringValue = rest.isEmpty ? "" : "+ " + rest.joined(separator: "  ")
    layout(height: rest.isEmpty ? 74 : 90)
}

refresh()
w.orderFront(nil)

// Count down while the HUD is on screen.
let ticker = Foundation.Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
    refresh()
}
RunLoop.main.add(ticker, forMode: .common)

// Fallback auto-dismiss (normally killed by Karabiner on key release)
DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
    app.terminate(nil)
}

app.run()
