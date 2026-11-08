// displayctl - turn the built-in display of this MacBook off or on.
//
// A disabled display leaves the display list of macOS. No windows go to it and
// it holds no place in the display arrangement. The lid can stay open.
//
// The `watch` command runs as an agent. It turns the built-in display off when
// exactly two external displays are connected. It turns the display on again
// for any other number. The agent decides after a change of the monitors, and
// again after the Mac wakes. At its own start, for example at login, the agent
// does not turn the display off. It leaves the display on, and the menu asks
// the user.
//
// The `menu` command shows an item in the menu bar. The item shows the state of
// the display and of the agent. It can turn the display on or off, and it can
// stop, start, or restart the agent. The build script also puts this binary in
// ~/Applications/displayctl.app. That app starts in the `menu` mode, and it is
// a login item that System Settings shows and can remove. The menu is separate
// from the agent, so it stays in the menu bar while the agent is stopped.
//
// macOS gives no public function to disable a display. This tool uses three
// private functions from the SkyLight framework. It finds them at run time. If
// a future version of macOS removes them, the tool reports the problem and
// makes no change.

import AppKit
import CoreGraphics
import Darwin
import Foundation
import ServiceManagement

// MARK: - Private SkyLight interface

private typealias ConfigRef = UnsafeMutableRawPointer?
private typealias BeginFn = @convention(c) (UnsafeMutablePointer<ConfigRef>) -> Int32
private typealias EnableFn = @convention(c) (ConfigRef, CGDirectDisplayID, Bool) -> Int32
private typealias CompleteFn = @convention(c) (ConfigRef, UInt32) -> Int32

// Apply the change to this login session only. A restart or a logout undoes it.
// This makes a stuck display impossible to keep.
private let configureForSession: UInt32 = 2

private struct SkyLight {
    let begin: BeginFn
    let enable: EnableFn
    let complete: CompleteFn

    static let shared: SkyLight? = {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(path, RTLD_LAZY) else { return nil }
        guard let b = dlsym(handle, "SLSBeginDisplayConfiguration"),
              let e = dlsym(handle, "SLSConfigureDisplayEnabled"),
              let c = dlsym(handle, "SLSCompleteDisplayConfiguration")
        else { return nil }
        return SkyLight(begin: unsafeBitCast(b, to: BeginFn.self),
                        enable: unsafeBitCast(e, to: EnableFn.self),
                        complete: unsafeBitCast(c, to: CompleteFn.self))
    }()

    func setEnabled(_ id: CGDirectDisplayID, _ on: Bool) -> Int32 {
        var config: ConfigRef = nil
        var err = begin(&config)
        if err != 0 { return err }
        err = enable(config, id, on)
        if err != 0 { return err }
        return complete(config, configureForSession)
    }
}

// MARK: - Logging

private let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

// Both agents write to the same log. The name tells which agent wrote a line.
private var logName = "displayctl"

private func log(_ message: String) {
    FileHandle.standardError.write("\(iso.string(from: Date())) \(logName): \(message)\n".data(using: .utf8)!)
}

// MARK: - Display queries

private func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    guard count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

// Return the id of the built-in display, or nil when it is not in the online
// list. A display leaves that list when this tool disables it. A display also
// leaves it for a moment while the window server reconfigures the desk, so nil
// alone does not tell why the display is gone. See builtinState().
private func liveBuiltinID() -> CGDirectDisplayID? {
    onlineDisplays().first { CGDisplayIsBuiltin($0) != 0 }
}

private func externalCount() -> Int {
    onlineDisplays().filter { CGDisplayIsBuiltin($0) == 0 }.count
}

// MARK: - The saved id of the built-in display
//
// A disabled display is not in the online list, so the tool cannot find its id
// again. Save the id to a file before the tool turns the display off. The
// fallback is 1, which is the usual id of the internal panel.

private let stateFile = "/tmp/.displayctl-builtin-id"

private func rememberBuiltin(_ id: CGDirectDisplayID) {
    try? "\(id)\n".write(toFile: stateFile, atomically: true, encoding: .utf8)
}

private func recallBuiltin() -> CGDirectDisplayID {
    guard let text = try? String(contentsOfFile: stateFile, encoding: .utf8),
          let value = UInt32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
          value != 0
    else { return 1 }
    return value
}

private func forgetBuiltin() {
    try? FileManager.default.removeItem(atPath: stateFile)
}

// The file also records the intent of the tool. The file exists only while the
// tool holds the display off. The file lives in /tmp, so a restart clears it.
// A restart also restores the display, because the change has session scope.
private func toolHoldsBuiltinOff() -> Bool {
    FileManager.default.fileExists(atPath: stateFile)
}

// MARK: - The decision
//
// These two types hold all of the logic that does not touch the hardware. The
// `selftest` command checks them.

enum BuiltinState {
    case on          // the display is in the online list
    case offByTool   // the display is absent and this tool turned it off
    case unknown     // the display is absent for some other reason
}

enum Action: Equatable {
    case none        // the display is already in the wanted state
    case turnOn
    case turnOff
    case waitUnknown // the state is not certain, so make no change now
}

func plan(wanted: Bool, state: BuiltinState) -> Action {
    switch (wanted, state) {
    case (true, .on): return .none
    case (false, .on): return .turnOff
    case (true, .offByTool): return .turnOn
    case (false, .offByTool): return .none
    // An enable of a display that is already live changes nothing, so the tool
    // can turn the display on without knowing the state.
    case (true, .unknown): return .turnOn
    // The display may be on and absent from the list for only a moment. A
    // disable now would do nothing and would still count as done, and the
    // display would stay on. Wait for a state that is certain.
    case (false, .unknown): return .waitUnknown
    }
}

// The number of externals at the last decision. The agent acts only when this
// number changes, so a manual change to the display stays until the desk
// changes.
struct Latch {
    private(set) var lastExternals: Int? = nil

    func isUnchanged(externals: Int) -> Bool { lastExternals == externals }

    // Hold the count only when the display really reached the wanted state. A
    // change that did not happen leaves the latch open, so the next look tries
    // again instead of reporting no change in the set of monitors.
    mutating func record(externals: Int, applied: Bool) {
        lastExternals = applied ? externals : nil
    }

    // Drop the count. The agent calls this after a wake, because the monitors
    // can change while the Mac sleeps and that change raises no event.
    mutating func forget() {
        lastExternals = nil
    }
}

// The count of externals for which the agent waits for the user. At its start,
// the agent leaves the display on and the menu asks the user. The wait holds
// until the count changes, also after a wake. Thus an answer of "Keep On" lasts
// while the set of monitors stays the same.
struct UserHold {
    private(set) var externals: Int? = nil

    mutating func hold(externals count: Int) { externals = count }

    // True while the count is the count of the hold. A different count ends the
    // hold for good.
    mutating func waits(externals count: Int) -> Bool {
        guard let held = externals else { return false }
        if held == count { return true }
        externals = nil
        return false
    }
}

// The agent writes this file when it waits for the user. The file holds the
// count of externals. The menu reads it, asks the user, and removes it. The file
// lives in /tmp, so a restart clears it.
private let askFile = "/tmp/.displayctl-ask"

private func writeAsk(externals: Int) {
    try? "\(externals)\n".write(toFile: askFile, atomically: true, encoding: .utf8)
}

private func removeAsk() {
    try? FileManager.default.removeItem(atPath: askFile)
}

private func builtinState() -> BuiltinState {
    if liveBuiltinID() != nil { return .on }
    return toolHoldsBuiltinOff() ? .offByTool : .unknown
}

// MARK: - Apply a state

// The window server finishes a change a moment after the call returns. Look at
// the display list until it agrees with the wanted state, or until the time
// runs out. A change that the list never confirms counts as a failure.
private func waitForBuiltin(on wanted: Bool, timeout: TimeInterval = 2.0) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if (liveBuiltinID() != nil) == wanted { return true }
        usleep(100_000)
    } while Date() < deadline
    return (liveBuiltinID() != nil) == wanted
}

@discardableResult
private func applyBuiltin(on wanted: Bool, dryRun: Bool) -> Bool {
    switch plan(wanted: wanted, state: builtinState()) {
    case .none:
        return true
    case .waitUnknown:
        log("the built-in display is not in the display list, and this tool did not turn it off, so the state is not certain; making no change")
        return false
    case .turnOn, .turnOff:
        break
    }

    // Never disable the last display. That would leave no screen at all.
    if !wanted && onlineDisplays().count < 2 {
        log("refusing to disable the built-in display because it is the only one")
        return false
    }

    let id = liveBuiltinID() ?? recallBuiltin()
    if dryRun {
        log("dry run: would turn display \(id) \(wanted ? "on" : "off")")
        return true
    }

    guard let sky = SkyLight.shared else {
        log("the SkyLight functions are missing, so this version of macOS is not supported")
        return false
    }

    // Save the id before the change. A disabled display leaves the display
    // list, so the tool cannot read the id again after the change.
    if !wanted { rememberBuiltin(id) }

    let err = sky.setEnabled(id, wanted)
    if err != 0 {
        log("failed to turn display \(id) \(wanted ? "on" : "off"), error \(err)")
        if !wanted { forgetBuiltin() }
        return false
    }
    if !waitForBuiltin(on: wanted) {
        log("the call to turn display \(id) \(wanted ? "on" : "off") reported no error, but the display list does not agree")
        if !wanted { forgetBuiltin() }
        return false
    }
    if wanted { forgetBuiltin() }
    log("display \(id) is now \(wanted ? "on" : "off")")
    return true
}

// MARK: - Watch mode

private var latch = Latch()
private var userHold = UserHold()

// A change that did not happen gets another look, because the state that
// blocked it is short. Without this the agent would wait for the next change in
// the set of monitors.
private let retryDelay: TimeInterval = 4.0
private let retryLimit = 5
private var retriesLeft = retryLimit

private func scheduleRetry() {
    guard retriesLeft > 0 else {
        log("no more retries, so the display stays as it is until the set of monitors changes")
        return
    }
    retriesLeft -= 1
    DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { evaluate(reason: "retry") }
}

// The agent changes the display itself, and that change raises another
// callback. This flag stops the agent from reacting to its own work.
private var applyingOwnChange = false

private var debounceGeneration = 0
private var watchDryRun = false

// Turn the built-in display off only for exactly two external displays.
private func builtinShouldBeOn(externals: Int) -> Bool { externals != 2 }

private func evaluate(reason: String) {
    if applyingOwnChange { return }

    let externals = externalCount()
    if userHold.waits(externals: externals) {
        log("\(reason): \(externals) external(s), the choice is the user's, leaving the display alone")
        return
    }
    // No hold, or the set of monitors changed. A question that is still open is
    // then out of date.
    removeAsk()

    if latch.isUnchanged(externals: externals) {
        log("\(reason): \(externals) external(s), no change in the set of monitors, leaving the display alone")
        return
    }

    let wanted = builtinShouldBeOn(externals: externals)
    log("\(reason): \(externals) external(s), the built-in display should be \(wanted ? "on" : "off")")

    // At its start the agent does not turn the display off. The start is often
    // at login, and a change of the displays then slows the login and can go
    // wrong. Leave the display on, and let the menu ask the user.
    if reason == "start" && plan(wanted: wanted, state: builtinState()) == .turnOff {
        userHold.hold(externals: externals)
        writeAsk(externals: externals)
        log("start: the display stays on until the user chooses in the menu")
        return
    }

    applyingOwnChange = true
    let applied = applyBuiltin(on: wanted, dryRun: watchDryRun)
    latch.record(externals: externals, applied: applied)
    if !applied { scheduleRetry() }

    // Release the guard after the events from our own change are done.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { applyingOwnChange = false }
}

// A dock sends many events in a burst. Wait for the burst to stop, then look at
// the result one time.
private func scheduleEvaluate(reason: String) {
    retriesLeft = retryLimit
    debounceGeneration += 1
    let generation = debounceGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        if generation == debounceGeneration { evaluate(reason: reason) }
    }
}

private let reconfigCallback: CGDisplayReconfigurationCallBack = { _, flags, _ in
    // Ignore the "before the change" event. Look only at the finished state.
    if flags.contains(.beginConfigurationFlag) { return }
    scheduleEvaluate(reason: "display change")
}

private func installSignalHandlers() {
    // Turn the display back on when the agent stops. Without this an unload
    // would leave the panel off until the next logout.
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            log("stopping, so the built-in display goes back on")
            removeAsk()
            applyBuiltin(on: true, dryRun: watchDryRun)
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }
}

private var signalSources: [DispatchSourceSignal] = []

// A change of the display list is not the only reason to decide. When the last
// external display goes away while the lid is closed, macOS sleeps about one
// second later. That is less than the debounce, so the agent never looks at the
// new desk. On wake the display list already holds the new state, so no event
// arrives, and the built-in display stays off. The Mac then shows nothing.
//
// A wake is the second reason to decide. Drop the count of externals first. The
// latch still holds the count from before the sleep, and a count that did not
// change would stop the agent from acting.
private func installWakeObserver() {
    NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification,
        object: nil,
        queue: .main
    ) { _ in
        log("the Mac woke up, so the set of monitors is not known any more")
        latch.forget()
        scheduleEvaluate(reason: "wake")
    }
}

private func watch(dryRun: Bool) -> Never {
    watchDryRun = dryRun
    log("watch started\(dryRun ? " in dry run mode" : "")")
    if SkyLight.shared == nil && !dryRun {
        log("warning: the SkyLight functions are missing, so no change is possible")
    }
    // A callback for a display change goes only to a process that has a
    // connection to the window server. AppKit makes that connection. Without
    // this line the agent gets no event when a monitor comes or goes.
    // The policy keeps the agent out of the Dock and out of the menu bar.
    NSApplication.shared.setActivationPolicy(.prohibited)

    installSignalHandlers()
    installWakeObserver()
    CGDisplayRegisterReconfigurationCallback(reconfigCallback, nil)
    // Set the correct state at login, before any event arrives.
    evaluate(reason: "start")
    CFRunLoopRun()
    exit(0)
}

// MARK: - Control of the watch agent
//
// The menu controls the watch agent with the same launchctl commands as the
// `,displayctl` shell function.

private let agentLabel = "com.zaid.displayctl"
private let agentPlist = NSHomeDirectory() + "/Library/LaunchAgents/\(agentLabel).plist"
private let logPath = NSHomeDirectory() + "/Library/Logs/displayctl.log"
private let agentTarget = "gui/\(getuid())/\(agentLabel)"

enum AgentState: Equatable {
    case running(pid: Int32)
    case loaded(lastExit: String) // launchd holds the job, but no process runs
    case stopped                  // launchd does not hold the job
}

// Read the output of `launchctl print`, or nil when launchctl does not know the
// job. Only the top-level keys count. The nested sections of the output have
// their own "state" lines, with a deeper indent.
func parseAgentState(_ output: String?) -> AgentState {
    guard let output else { return .stopped }
    var state = ""
    var pid: Int32? = nil
    var lastExit = "unknown"
    for line in output.split(separator: "\n") {
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

@discardableResult
private func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func readAgentState() -> AgentState {
    let result = launchctl(["print", agentTarget])
    return parseAgentState(result.status == 0 ? result.output : nil)
}

private func agentIsLoaded() -> Bool {
    launchctl(["print", agentTarget]).status == 0
}

// A bootout returns before the agent stops. The agent turns the display back on
// first, and the plist gives it 20 seconds for that. Wait for 25 seconds at most.
private func stopAgent() -> Bool {
    guard agentIsLoaded() else { return true }
    launchctl(["bootout", agentTarget])
    for _ in 0..<250 {
        if !agentIsLoaded() { return true }
        usleep(100_000)
    }
    log("the agent did not stop in 25 seconds")
    return false
}

private func startAgent() -> Bool {
    guard !agentIsLoaded() else { return true }
    let result = launchctl(["bootstrap", "gui/\(getuid())", agentPlist])
    if result.status != 0 {
        log("could not start the agent: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        return false
    }
    return true
}

// MARK: - Menu bar item

private final class MenuController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var agent: AgentState = .stopped
    // The agent action that runs now, for example "Restarting". Nil when no
    // action runs. The menu blocks the other agent actions until it is done.
    private var busy: String? = nil
    private var timer: Timer?
    // True while the question about the display is on the screen.
    private var asking = false

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refresh()
        // A crash or a launchctl command in a shell changes the agent and
        // raises no event here. Look again at a fixed interval. The same look
        // finds a question from the agent.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.askIfAgentWaits()
        }
    }

    // Wait this long after the agent starts before the question shows. The
    // agent starts at login, and the login is still busy for some seconds.
    private let askDelay: TimeInterval = 10

    // The agent leaves the display on at its start and writes the ask file.
    // Ask the user, then remove the file, so the question shows one time only.
    private func askIfAgentWaits() {
        guard !asking,
              let attributes = try? FileManager.default.attributesOfItem(atPath: askFile),
              let written = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(written) >= askDelay
        else { return }
        let text = (try? String(contentsOfFile: askFile, encoding: .utf8)) ?? ""
        removeAsk()
        guard let externals = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              externalCount() == externals,
              builtinState() == .on
        else { return }

        asking = true
        let alert = NSAlert()
        alert.messageText = "Turn off the built-in display?"
        alert.informativeText = "\(externals) external displays are connected. The built-in display stays on until you choose. You can also turn it off later from the menu bar."
        alert.icon = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil)
        alert.addButton(withTitle: "Turn Off")
        alert.addButton(withTitle: "Keep On")
        // An accessory app is not in front by itself, and the alert would open
        // behind the other windows.
        NSApp.activate()
        let answer = alert.runModal()
        asking = false

        guard answer == .alertFirstButtonReturn else {
            log("the user chose to keep the built-in display on")
            return
        }
        // The alert can stay open for a long time. Turn the display off only if
        // the set of monitors is still the same.
        guard externalCount() == externals else {
            log("the set of monitors changed while the question was open, so no change")
            return
        }
        log("the user chose to turn the built-in display off")
        runTool("off")
    }

    func refresh() {
        agent = readAgentState()
        updateIcon()
    }

    // The icon shows the built-in display. It is dim when the agent does not run.
    func updateIcon() {
        guard let button = item.button else { return }
        let displayOn = liveBuiltinID() != nil
        let name = displayOn ? "laptopcomputer" : "laptopcomputer.slash"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "displayctl")
            ?? NSImage(systemSymbolName: "display", accessibilityDescription: "displayctl")
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = busy != nil || !agentIsRunning
        button.toolTip = "Built-in display: \(displayLine)\nAgent: \(agentLine)"
    }

    private var agentIsRunning: Bool {
        if case .running = agent { return true }
        return false
    }

    private var displayLine: String {
        switch builtinState() {
        case .on: return "on"
        case .offByTool: return "off"
        case .unknown: return "not in the display list"
        }
    }

    private var agentLine: String {
        if let busy { return "\(busy)…" }
        switch agent {
        case .running(let pid): return "running (pid \(pid))"
        case .loaded(let lastExit): return "not running (last exit \(lastExit))"
        case .stopped: return "stopped"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()

        menu.addItem(info("Built-in display: \(displayLine)"))
        menu.addItem(info("External displays: \(externalCount())"))
        menu.addItem(info("Agent: \(agentLine)"))
        menu.addItem(.separator())

        let displayOn = builtinState() == .on
        let toggle = action(displayOn ? "Turn Built-in Display Off" : "Turn Built-in Display On",
                            #selector(toggleDisplay))
        // The tool never turns off the last display.
        toggle.isEnabled = !displayOn || onlineDisplays().count >= 2
        if agentIsRunning {
            toggle.toolTip = "The agent decides again when a monitor comes or goes, or after the Mac wakes."
        }
        menu.addItem(toggle)
        menu.addItem(.separator())

        let restart = action("Restart Agent", #selector(restartAgent))
        restart.isEnabled = busy == nil && agent != .stopped
        menu.addItem(restart)
        let startStop = agent == .stopped
            ? action("Start Agent", #selector(startAgentAction))
            : action("Stop Agent", #selector(stopAgentAction))
        startStop.isEnabled = busy == nil
        if agent != .stopped {
            startStop.toolTip = "The built-in display goes back on. The agent stays stopped until you start it or log in again."
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

        menu.addItem(action("Open Log", #selector(openLog)))
        menu.addItem(action("Quit displayctl Menu", #selector(quit)))
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

    @objc private func toggleDisplay() {
        log("toggle the built-in display from the menu")
        runTool("toggle")
    }

    // Run the tool as a child process. The child writes to the same log, and
    // the wait for the display does not block the menu.
    private func runTool(_ command: String) {
        guard let path = Bundle.main.executablePath else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [command]
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        try? process.run()
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

    // A stop can take 20 seconds, so the work runs off the main thread.
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

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    // A quit holds until the next login, or until you open the app again.
    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private var menuController: MenuController?

private let menuReconfigCallback: CGDisplayReconfigurationCallBack = { _, flags, _ in
    if flags.contains(.beginConfigurationFlag) { return }
    // The window server finishes the change a moment after the event.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { menuController?.updateIcon() }
}

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
    logName = "displayctl menu"
    // An app that LaunchServices opens has no stderr. Send it to the log of the
    // agent, so both write one record. The child that "toggle" starts gets the
    // same stderr.
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
    CGDisplayRegisterReconfigurationCallback(menuReconfigCallback, nil)
    app.run()
    exit(0)
}

// MARK: - Self test
//
// These checks run on any Mac and touch no hardware. They cover the decision
// and the latch, which is where the agent lost the display state before.

private func selftest() -> Bool {
    var failures = 0

    func check(_ name: String, _ got: Any, _ want: Any) {
        let ok = "\(got)" == "\(want)"
        if !ok { failures += 1 }
        print("\(ok ? "ok  " : "FAIL") \(name): got \(got), want \(want)")
    }

    // The display is in the list, so the state is certain.
    check("on, want on", plan(wanted: true, state: .on), Action.none)
    check("on, want off", plan(wanted: false, state: .on), Action.turnOff)

    // The tool turned the display off, so the state is certain.
    check("offByTool, want on", plan(wanted: true, state: .offByTool), Action.turnOn)
    check("offByTool, want off", plan(wanted: false, state: .offByTool), Action.none)

    // The display is absent for some other reason. Turning it on is safe,
    // because an enable of a live display changes nothing. Turning it off is
    // not safe, because the display may be on and merely absent for a moment.
    check("unknown, want on", plan(wanted: true, state: .unknown), Action.turnOn)
    check("unknown, want off", plan(wanted: false, state: .unknown), Action.waitUnknown)

    // The latch must hold the count only after the display really moved. A
    // change that did not happen must leave the latch open, so the next look
    // tries again instead of reporting no change.
    var latch = Latch()
    latch.record(externals: 2, applied: true)
    check("latch after a change that worked", latch.isUnchanged(externals: 2), true)

    var open = Latch()
    open.record(externals: 2, applied: false)
    check("latch after a change that failed", open.isUnchanged(externals: 2), false)

    // A wake must always lead to a decision. The monitors can change while the
    // Mac sleeps, and the same count must not look like no change.
    var woken = Latch()
    woken.record(externals: 2, applied: true)
    woken.forget()
    check("latch after a wake", woken.isUnchanged(externals: 2), false)

    // The hold from the start must last while the count stays the same, also
    // after a wake. A new count must end it for good, so that a later return
    // to the same count acts as usual.
    var hold = UserHold()
    hold.hold(externals: 2)
    check("hold, same count", hold.waits(externals: 2), true)
    check("hold, new count", hold.waits(externals: 1), false)
    check("hold after a new count", hold.waits(externals: 2), false)

    // The menu reads the agent state from `launchctl print`. The nested
    // sections have their own "state" lines, and they must not count.
    let running = "gui/501/x = {\n\tstate = running\n\tpid = 42\n\tsockets = {\n\t\tstate = active\n\t}\n}"
    let waiting = "gui/501/x = {\n\tstate = not running\n\tlast exit code = 78\n\t\tstate = active\n}"
    check("agent running", parseAgentState(running), AgentState.running(pid: 42))
    check("agent loaded, not running", parseAgentState(waiting), AgentState.loaded(lastExit: "78"))
    check("agent not loaded", parseAgentState(nil), AgentState.stopped)

    print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
    return failures == 0
}

// MARK: - Command line

private func printList() {
    for id in onlineDisplays() {
        let bounds = CGDisplayBounds(id)
        let kind = CGDisplayIsBuiltin(id) != 0 ? "built-in" : "external"
        print("id=\(id) \(kind) \(Int(bounds.width))x\(Int(bounds.height))")
    }
    let externals = externalCount()
    switch builtinState() {
    case .on:
        break
    case .offByTool:
        print("built-in display: OFF (saved id \(recallBuiltin()))")
    case .unknown:
        print("built-in display: not in the display list, and this tool did not turn it off")
    }
    print("externals: \(externals), the built-in display should be \(builtinShouldBeOn(externals: externals) ? "on" : "off")")
}

let arguments = Array(CommandLine.arguments.dropFirst())
// The app starts with no arguments, and it must show the menu.
let command = arguments.first ?? (runsAsApp ? "menu" : "list")
let dryRun = arguments.contains("--dry-run")

switch command {
case "list":
    printList()
case "on":
    exit(applyBuiltin(on: true, dryRun: dryRun) ? 0 : 1)
case "off":
    exit(applyBuiltin(on: false, dryRun: dryRun) ? 0 : 1)
case "toggle":
    exit(applyBuiltin(on: builtinState() != .on, dryRun: dryRun) ? 0 : 1)
case "watch":
    watch(dryRun: dryRun)
case "menu":
    runMenu()
case "selftest":
    exit(selftest() ? 0 : 1)
default:
    print("usage: displayctl [list|on|off|toggle|watch|menu|selftest] [--dry-run]")
    exit(2)
}
