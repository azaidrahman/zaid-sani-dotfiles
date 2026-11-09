// gamekeys - turn off the Karabiner keybinds while a game is in front.
//
// The `watch` command runs as an agent. It watches the frontmost app. If the
// app is a game, the agent selects the "Game" profile of Karabiner-Elements.
// That profile has no complex rules, so the hyper key, the layers, and the app
// keys stop. When a different app comes to the front, the agent selects the
// earlier profile again.
//
// An app is a game if its Info.plist puts it in a games category, or if it
// supports Game Mode. macOS uses the same keys to decide on Game Mode, so this
// check also covers Game Mode.
//
// The agent does not change a profile that it did not select. For example,
// while `,guest-mode` holds the "Guest" profile, the agent does nothing.
//
// The `menu` command shows an item in the menu bar. The item shows if the
// keybinds are on or off, and the state of the agent. It can stop, start, or
// restart the agent. The build script also puts this binary in
// ~/Applications/gamekeys.app. That app starts in the `menu` mode, and it is a
// login item that System Settings shows and can remove.
//
// The goku script in chezmoi makes the "Game" profile, from the device
// settings of the main profile.

import AppKit
import Darwin
import Foundation
import ServiceManagement

private let cli = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
private let gameProfile = "Game"
private let mainProfile = "Zaid"
// The agent never replaces these profiles with the "Game" profile.
private let foreignProfiles: Set<String> = ["Guest"]

private let agentLabel = "com.zaid.gamekeys"
private let agentPlist = NSHomeDirectory() + "/Library/LaunchAgents/\(agentLabel).plist"
private let agentTarget = "gui/\(getuid())/\(agentLabel)"
private let logPath = NSHomeDirectory() + "/Library/Logs/gamekeys.log"
// The agent posts this notification after it selects a profile. The menu then
// updates its icon at once.
private let changedNotification = Notification.Name("com.zaid.gamekeys.changed")

private var logName = "gamekeys"

private func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("\(stamp) [\(logName)] \(message)\n".data(using: .utf8)!)
}

private func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return (process.terminationStatus, output)
}

// MARK: - Karabiner

private func currentProfile() -> String? {
    let result = run(cli, ["--show-current-profile-name"])
    return result.status == 0 ? result.output : nil
}

private func select(_ profile: String) {
    let result = run(cli, ["--select-profile", profile])
    guard result.status == 0 else {
        log("could not select the profile \(profile): \(result.output)")
        return
    }
    log("profile -> \(profile)")
    DistributedNotificationCenter.default().postNotificationName(
        changedNotification, object: nil, userInfo: nil, deliverImmediately: true)
}

private func isGame(_ app: NSRunningApplication?) -> Bool {
    guard let url = app?.bundleURL, let info = Bundle(url: url)?.infoDictionary else {
        return false
    }
    if let category = info["LSApplicationCategoryType"] as? String,
       category == "public.app-category.games" || category.hasSuffix("-games") {
        return true
    }
    return info["LSSupportsGameMode"] as? Bool == true
}

// MARK: - Agent

private final class Watcher {
    // The profile that was active before the agent selected "Game".
    private var previous: String?

    func update(for app: NSRunningApplication?) {
        guard let current = currentProfile() else { return }
        if isGame(app) {
            if foreignProfiles.contains(current) {
                log("game in front, but the profile \(current) holds, so no change")
                return
            }
            guard current != gameProfile else { return }
            log("game in front: \(app?.bundleIdentifier ?? "?")")
            previous = current
            select(gameProfile)
        } else {
            if current == gameProfile {
                log("not a game in front: \(app?.bundleIdentifier ?? "?")")
            }
            restore(current: current)
        }
    }

    // Select the earlier profile again, but only if "Game" is still active.
    // After a crash, `previous` is empty, so use the main profile.
    func restore(current: String? = currentProfile()) {
        guard current == gameProfile else { return }
        select(previous ?? mainProfile)
        previous = nil
    }
}

private var signalSources: [DispatchSourceSignal] = []

// Keep the last 2000 lines when the log is larger than 1 MB. launchd holds the
// log open, so cut the file in place. A new file would leave launchd writing
// to the old one.
private func trimLog() {
    guard let size = (try? FileManager.default.attributesOfItem(atPath: logPath))?[.size] as? Int,
          size > 1_000_000,
          let text = try? String(contentsOfFile: logPath, encoding: .utf8),
          let handle = FileHandle(forWritingAtPath: logPath)
    else { return }
    let kept = text.split(separator: "\n").suffix(2000).joined(separator: "\n") + "\n"
    try? handle.truncate(atOffset: 0)
    handle.write(kept.data(using: .utf8)!)
    try? handle.close()
}

private func watch() -> Never {
    trimLog()
    let watcher = Watcher()
    NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        queue: .main
    ) { note in
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        watcher.update(for: app)
    }

    // A stop of the agent gives the keybinds back.
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            watcher.restore()
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }

    log("started")
    watcher.update(for: NSWorkspace.shared.frontmostApplication)
    RunLoop.main.run()
    exit(0)
}

// MARK: - Control of the agent

enum AgentState: Equatable {
    case running(pid: Int32)
    case loaded(lastExit: String) // launchd holds the job, but no process runs
    case stopped                  // launchd does not hold the job
}

// Read the output of `launchctl print`. Only the top-level keys count. The
// nested sections of the output have their own "state" lines, with a deeper
// indent.
private func readAgentState() -> AgentState {
    let result = run("/bin/launchctl", ["print", agentTarget])
    guard result.status == 0 else { return .stopped }
    var state = ""
    var pid: Int32? = nil
    var lastExit = "unknown"
    for line in result.output.split(separator: "\n") {
        guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
        let parts = line.split(separator: "=", maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { continue }
        switch parts[0] {
        case "state": state = parts[1]
        case "pid": pid = Int32(parts[1])
        case "last exit code": lastExit = parts[1]
        default: break
        }
    }
    if state == "running", let pid { return .running(pid: pid) }
    return .loaded(lastExit: lastExit)
}

private func agentIsLoaded() -> Bool {
    run("/bin/launchctl", ["print", agentTarget]).status == 0
}

// A bootout returns before the agent stops. Wait for 10 seconds at most.
private func stopAgent() -> Bool {
    guard agentIsLoaded() else { return true }
    _ = run("/bin/launchctl", ["bootout", agentTarget])
    for _ in 0..<100 {
        if !agentIsLoaded() { return true }
        usleep(100_000)
    }
    log("the agent did not stop in 10 seconds")
    return false
}

private func startAgent() -> Bool {
    guard !agentIsLoaded() else { return true }
    let result = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", agentPlist])
    if result.status != 0 {
        log("could not start the agent: \(result.output)")
        return false
    }
    return true
}

// MARK: - Menu bar item

private final class MenuController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var agent: AgentState = .stopped
    private var profile: String?
    // The agent action that runs now, for example "Restarting". Nil when no
    // action runs. The menu blocks the other agent actions until it is done.
    private var busy: String? = nil
    private var timer: Timer?

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refresh()
        DistributedNotificationCenter.default().addObserver(
            forName: changedNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
        // A crash, `,guest-mode`, or a launchctl command in a shell raises no
        // notification here. Look again at a fixed interval.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let oldAgent = agent, oldProfile = profile
        agent = readAgentState()
        profile = currentProfile()
        // Write each change to the log. The log then shows when the agent
        // stopped, and what the menu showed at that time.
        if agent != oldAgent { log("agent: \(agentLine)") }
        if profile != oldProfile { log("keybinds: \(keybindsLine)") }
        updateIcon()
    }

    private var keybindsOff: Bool { profile == gameProfile }

    private var agentIsRunning: Bool {
        if case .running = agent { return true }
        return false
    }

    // True when the agent runs and Karabiner answers.
    private var healthy: Bool { agentIsRunning && profile != nil }

    // The dot after the controller shows game mode. It is green while a game is
    // in front and the keybinds are off. It is red while the keybinds are on.
    // It is gray when the agent does not run or Karabiner does not answer, and
    // yellow while a menu action runs. The controller is filled in game mode.
    private func updateIcon() {
        guard let button = item.button else { return }
        let name = keybindsOff ? "gamecontroller.fill" : "gamecontroller"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "gamekeys")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeft
        let dot: NSColor
        if busy != nil {
            dot = .systemYellow
        } else if !healthy {
            dot = .systemGray
        } else {
            dot = keybindsOff ? .systemGreen : .systemRed
        }
        button.attributedTitle = NSAttributedString(string: "●", attributes: [
            .foregroundColor: dot,
            .font: NSFont.systemFont(ofSize: 9),
            .baselineOffset: 1,
        ])
        button.toolTip = "Keybinds: \(keybindsLine)\nAgent: \(agentLine)"
    }

    private var keybindsLine: String {
        guard let profile else { return "unknown (Karabiner does not answer)" }
        if keybindsOff { return "off (a game is in front)" }
        return "on (profile \(profile))"
    }

    private var agentLine: String {
        if let busy { return "\(busy)…" }
        switch agent {
        case .running(let pid): return "running (pid \(pid))"
        case .loaded(let lastExit): return "not running (last exit \(lastExit))"
        case .stopped: return "stopped"
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        log("menu opened (front: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"))")
    }

    func menuDidClose(_ menu: NSMenu) { log("menu closed") }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()

        menu.addItem(info("Keybinds: \(keybindsLine)"))
        menu.addItem(info("Agent: \(agentLine)"))
        menu.addItem(.separator())

        let restart = action("Restart Agent", #selector(restartAgent))
        restart.isEnabled = busy == nil && agent != .stopped
        menu.addItem(restart)
        let startStop = agent == .stopped
            ? action("Start Agent", #selector(startAgentAction))
            : action("Stop Agent", #selector(stopAgentAction))
        startStop.isEnabled = busy == nil
        if agent != .stopped {
            startStop.toolTip = "The keybinds come back on. The agent stays stopped until you start it or log in again."
        }
        menu.addItem(startStop)
        menu.addItem(.separator())

        let login = action("Open at Login", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        // Only the app has an identity that System Settings can list.
        login.isEnabled = runsAsApp
        menu.addItem(login)
        menu.addItem(action("Login Items Settings…", #selector(openLoginItems)))
        menu.addItem(.separator())

        menu.addItem(action("Copy Log for Claude", #selector(copyLog)))
        menu.addItem(action("Open Log", #selector(openLog)))
        menu.addItem(action("Quit gamekeys Menu", #selector(quit)))
    }

    private func info(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        return entry
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                log("removed the menu from the login items")
            } else {
                try service.register()
                log("added the menu to the login items")
            }
        } catch {
            log("could not change the login item: \(error.localizedDescription)")
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    @objc private func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc private func restartAgent() {
        runAgentAction("Restarting") { stopAgent() && startAgent() }
    }

    @objc private func startAgentAction() {
        runAgentAction("Starting") { startAgent() }
    }

    @objc private func stopAgentAction() {
        runAgentAction("Stopping") { stopAgent() }
    }

    // A stop waits for the agent, so the work runs off the main thread.
    private func runAgentAction(_ name: String, _ work: @escaping () -> Bool) {
        guard busy == nil else { return }
        busy = name
        updateIcon()
        log("\(name.lowercased()) the agent from the menu")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = work()
            DispatchQueue.main.async {
                self.busy = nil
                if !ok { log("\(name.lowercased()) the agent failed") }
                self.refresh()
            }
        }
    }

    // Copy a report to the clipboard: the state now, and the end of the log.
    @objc private func copyLog() {
        refresh()
        let front = NSWorkspace.shared.frontmostApplication
        let lines = ((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(200)
            .joined(separator: "\n")
        let report = """
        gamekeys report \(ISO8601DateFormatter().string(from: Date()))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        keybinds: \(keybindsLine)
        agent: \(agentLine)
        front app: \(front?.bundleIdentifier ?? "?") (game: \(isGame(front)))
        log (\(logPath), last 200 lines):
        \(lines)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        log("copied the report to the clipboard")
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    // A quit holds until the next login, or until you open the app again.
    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private var menuController: MenuController?

private let runsAsApp = Bundle.main.bundleURL.pathExtension == "app"

// Add the app to the login items one time only, at the first start. After that,
// the choice in System Settings or in the menu holds. Without this record, each
// start of the app would undo a removal.
private func registerLoginItemOnce() {
    let key = "loginItemRegistered"
    guard runsAsApp, !UserDefaults.standard.bool(forKey: key) else { return }
    UserDefaults.standard.set(true, forKey: key)
    do {
        try SMAppService.mainApp.register()
        log("added the menu to the login items")
    } catch {
        log("could not add the menu to the login items: \(error.localizedDescription)")
    }
}

private func runMenu() -> Never {
    logName = "gamekeys menu"
    // An app that LaunchServices opens has no stderr. Send it to the log of the
    // agent, so both write one record.
    let fd = open(logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    if fd >= 0 {
        dup2(fd, STDERR_FILENO)
        close(fd)
    }
    registerLoginItemOnce()
    let app = NSApplication.shared
    // An accessory app has a menu bar item, but no Dock icon.
    app.setActivationPolicy(.accessory)
    menuController = MenuController()
    app.run()
    exit(0)
}

// MARK: - Main

// The app has no arguments, so it starts in the `menu` mode.
switch CommandLine.arguments.dropFirst().first ?? "menu" {
case "watch":
    watch()
case "menu":
    runMenu()
default:
    FileHandle.standardError.write("usage: gamekeys [watch|menu]\n".data(using: .utf8)!)
    exit(2)
}
