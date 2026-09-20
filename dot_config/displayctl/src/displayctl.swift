// displayctl - turn the built-in display of this MacBook off or on.
//
// A disabled display leaves the display list of macOS. No windows go to it and
// it holds no place in the display arrangement. The lid can stay open.
//
// The `watch` command runs as an agent. It turns the built-in display off when
// exactly two external displays are connected. It turns the display on again
// for any other number. The agent decides after a change of the monitors, and
// again after the Mac wakes.
//
// macOS gives no public function to disable a display. This tool uses three
// private functions from the SkyLight framework. It finds them at run time. If
// a future version of macOS removes them, the tool reports the problem and
// makes no change.

import AppKit
import CoreGraphics
import Darwin
import Foundation

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

private func log(_ message: String) {
    FileHandle.standardError.write("\(iso.string(from: Date())) displayctl: \(message)\n".data(using: .utf8)!)
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
    if latch.isUnchanged(externals: externals) {
        log("\(reason): \(externals) external(s), no change in the set of monitors, leaving the display alone")
        return
    }

    let wanted = builtinShouldBeOn(externals: externals)
    log("\(reason): \(externals) external(s), the built-in display should be \(wanted ? "on" : "off")")

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
let command = arguments.first ?? "list"
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
case "selftest":
    exit(selftest() ? 0 : 1)
default:
    print("usage: displayctl [list|on|off|toggle|watch|selftest] [--dry-run]")
    exit(2)
}
