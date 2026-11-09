// gamekeys - turn off the Karabiner keybinds while a game is in front.
//
// The agent watches the frontmost app. If the app is a game, the agent selects
// the "Game" profile of Karabiner-Elements. That profile has no complex rules,
// so the hyper key, the layers, and the app keys stop. When a different app
// comes to the front, the agent selects the earlier profile again.
//
// An app is a game if its Info.plist puts it in a games category, or if it
// supports Game Mode. macOS uses the same keys to decide on Game Mode, so this
// check also covers Game Mode.
//
// The agent does not change a profile that it did not select. For example,
// while `,guest-mode` holds the "Guest" profile, the agent does nothing.
//
// The build script in chezmoi makes the "Game" profile, from the device
// settings of the main profile.

import AppKit
import Darwin
import Foundation

private let cli = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
private let gameProfile = "Game"
private let mainProfile = "Zaid"
// The agent never replaces these profiles with the "Game" profile.
private let foreignProfiles: Set<String> = ["Guest"]

private func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("\(stamp) \(message)\n".data(using: .utf8)!)
}

@discardableResult
private func karabiner(_ args: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: cli)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        log("karabiner_cli failed: \(error)")
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        log("karabiner_cli \(args.joined(separator: " ")) exited with \(process.terminationStatus)")
        return nil
    }
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func currentProfile() -> String? {
    karabiner(["--show-current-profile-name"])
}

private func select(_ profile: String) {
    if karabiner(["--select-profile", profile]) != nil {
        log("profile -> \(profile)")
    }
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

private final class Watcher {
    // The profile that was active before the agent selected "Game".
    private var previous: String?

    func update(for app: NSRunningApplication?) {
        guard let current = currentProfile() else { return }
        if isGame(app) {
            guard current != gameProfile, !foreignProfiles.contains(current) else { return }
            log("game in front: \(app?.bundleIdentifier ?? "?")")
            previous = current
            select(gameProfile)
        } else {
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

private let watcher = Watcher()

NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification,
    object: nil,
    queue: .main
) { note in
    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    watcher.update(for: app)
}

// A stop of the agent gives the keybinds back.
private var signalSources: [DispatchSourceSignal] = []
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
