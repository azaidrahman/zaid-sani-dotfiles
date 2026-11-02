// op-sa-window — hold the 1Password service-account tokens in memory for a
// limited time. This time is "the window". `op-sa unlock` opens the window
// after one approval in 1Password. While the window is open, op-sa and
// git-credential-op get secrets from this helper with no prompt.
//
// The helper runs as the LaunchAgent com.zaid.op-sa-window. It listens on
// ~/.local/state/op-sa-window/sock. The folder has mode 0700, and the helper
// answers only connections from the same user.
//
// While the window is closed, the helper holds no secret. When the window
// runs out, or when you run `op-sa lock`, the helper sets each secret to zero
// and stops. launchd then starts a new, empty helper. If the helper does not
// run, a client gets "closed". Thus a failure closes the window. A failure
// never keeps a secret.
//
// The end of the window uses the wall clock, so time while the Mac sleeps
// counts.
//
// Usage:
//   op-sa-window serve          run the helper (launchd does this)
//   op-sa-window open SECONDS   open the window with the KEY=VALUE lines on stdin
//   op-sa-window get KEY        print the value of KEY
//   op-sa-window put KEY        keep the value on stdin as KEY
//   op-sa-window del KEY        remove KEY
//   op-sa-window ttl            print the number of seconds that are left
//   op-sa-window lock           close the window now
//
// The exit status of a client:
//   0  done
//   2  a bad request
//   3  the window is closed, or the helper does not answer
//   4  the window is open, but KEY is not in it
//
// Secrets go through stdin, stdout, and the socket only. They never go in
// arguments or in the environment, because `ps` can show those.
//
// Each Mac compiles this file (run_onchange_after_build-op-sa-window.sh).

import Darwin
import Dispatch

let maxWindowSeconds = 12 * 60 * 60
let maxMessageBytes = 64 * 1024
let serverTimeoutSeconds = 2
let clientTimeoutSeconds = 5
let openWaitSeconds = 8

enum Status: UInt8 {
    case ok = 0
    case bad = 2
    case closed = 3
    case missing = 4
}

// MARK: - Bytes

// Set the bytes to zero, then release them.
func wipe(_ bytes: inout [UInt8]) {
    bytes.withUnsafeMutableBytes { raw in
        if let base = raw.baseAddress, raw.count > 0 {
            _ = memset_s(base, raw.count, 0, raw.count)
        }
    }
    bytes.removeAll()
}

func wipe(_ entries: inout [String: [UInt8]]) {
    for key in Array(entries.keys) {
        if var value = entries.removeValue(forKey: key) {
            wipe(&value)
        }
    }
}

func writeAll(_ fd: Int32, _ bytes: [UInt8], from start: Int = 0) -> Bool {
    var offset = start
    while offset < bytes.count {
        let n = bytes.withUnsafeBytes { raw in
            write(fd, raw.baseAddress! + offset, raw.count - offset)
        }
        if n < 0 {
            if errno == EINTR { continue }
            return false
        }
        offset += n
    }
    return true
}

// Read until the end of the input. Return nil if the input is longer than
// limit, or if the read fails or times out. The result uses one buffer, so no
// old copy of a secret stays in memory.
func readAll(_ fd: Int32, limit: Int) -> [UInt8]? {
    var out = [UInt8]()
    out.reserveCapacity(limit)
    var chunk = [UInt8](repeating: 0, count: 4096)
    defer { wipe(&chunk) }
    while true {
        let n = chunk.withUnsafeMutableBytes { raw in
            read(fd, raw.baseAddress, raw.count)
        }
        if n == 0 { return out }
        if n < 0 {
            if errno == EINTR { continue }
            wipe(&out)
            return nil
        }
        if out.count + n > limit {
            wipe(&out)
            return nil
        }
        out.append(contentsOf: chunk[0..<n])
    }
}

func warn(_ message: String) {
    _ = writeAll(2, Array("op-sa-window: \(message)\n".utf8))
}

// MARK: - Socket

func homeDirectory() -> String {
    if let home = getenv("HOME") {
        return String(cString: home)
    }
    if let entry = getpwuid(getuid()) {
        return String(cString: entry.pointee.pw_dir)
    }
    warn("cannot find the home folder")
    exit(1)
}

let stateDirectory = homeDirectory() + "/.local/state/op-sa-window"
let socketPath = stateDirectory + "/sock"

func fileType(_ path: String) -> mode_t? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return info.st_mode & 0o170000
}

// Make the folder of the socket. Only this user can use it.
func makePrivateDirectory(_ path: String) -> Bool {
    var built = ""
    for part in path.split(separator: "/") {
        built += "/" + part
        if mkdir(built, 0o755) != 0 && errno != EEXIST {
            return false
        }
    }
    var info = stat()
    guard lstat(path, &info) == 0,
          info.st_mode & 0o170000 == 0o040000,
          info.st_uid == geteuid() else {
        return false
    }
    return chmod(path, 0o700) == 0
}

func socketAddress(_ path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        return nil
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes)
    }
    return address
}

func connectTo(_ address: sockaddr_un) -> Int32? {
    var address = address
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    let rc = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if rc != 0 {
        close(fd)
        return nil
    }
    return fd
}

func setTimeouts(_ fd: Int32, seconds: Int) {
    var limit = timeval(tv_sec: seconds, tv_usec: 0)
    let size = socklen_t(MemoryLayout<timeval>.size)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, size)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, size)
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
}

// MARK: - Server

// Parse the KEY=VALUE lines of an open request.
func parseEntries(_ payload: [UInt8]) -> [String: [UInt8]]? {
    var entries: [String: [UInt8]] = [:]
    for line in payload.split(separator: 10) {
        guard let equals = line.firstIndex(of: UInt8(ascii: "=")),
              equals > line.startIndex else {
            wipe(&entries)
            return nil
        }
        let key = String(decoding: line[line.startIndex..<equals], as: UTF8.self)
        entries[key] = Array(line[(equals + 1)...])
    }
    return entries.isEmpty ? nil : entries
}

// The state of the window. Use it only on `queue`.
final class Window {
    let queue = DispatchQueue(label: "op-sa-window.state")
    private var deadline = 0  // seconds since 1970; 0 means closed
    private var values: [String: [UInt8]] = [:]
    private var timer: DispatchSourceTimer?

    private func close() {
        wipe(&values)
        deadline = 0
    }

    // Stop the helper at the end of the window, also if no request comes.
    // The timer uses the wall clock. It fires again every 30 seconds in case
    // the Mac was asleep at the deadline.
    private func scheduleEnd() {
        timer?.cancel()
        let end = timespec(tv_sec: deadline, tv_nsec: 100_000_000)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(wallDeadline: DispatchWallTime(timespec: end),
                        repeating: .seconds(30), leeway: .milliseconds(100))
        source.setEventHandler { [unowned self] in
            if self.deadline > 0 && time(nil) >= self.deadline {
                self.close()
                exit(0)
            }
        }
        source.resume()
        timer = source
    }

    // Return the status, the payload of the answer, and true if the helper
    // must stop after the answer.
    func handle(_ request: [UInt8], now: Int) -> (Status, [UInt8], Bool) {
        guard let newline = request.firstIndex(of: 10) else {
            return (.bad, [], false)
        }
        let line = String(decoding: request[..<newline], as: UTF8.self)
        var payload = Array(request[(newline + 1)...])
        defer { wipe(&payload) }
        let words = line.split(separator: " ", maxSplits: 1)
        let command = words.first.map(String.init) ?? ""
        let argument = words.count > 1 ? String(words[1]) : ""

        var stop = false
        if deadline > 0 && now >= deadline {
            close()
            stop = command != "open"
        }
        let isOpen = deadline > 0

        switch command {
        case "open":
            guard let seconds = Int(argument), seconds > 0, seconds <= maxWindowSeconds,
                  let entries = parseEntries(payload) else {
                return (.bad, [], stop)
            }
            close()
            values = entries
            deadline = now + seconds
            scheduleEnd()
            return (.ok, [], false)
        case "get":
            guard isOpen else { return (.closed, [], stop) }
            guard let value = values[argument] else { return (.missing, [], stop) }
            return (.ok, value, stop)
        case "put":
            guard isOpen else { return (.closed, [], stop) }
            guard !argument.isEmpty else { return (.bad, [], stop) }
            if var old = values.removeValue(forKey: argument) {
                wipe(&old)
            }
            values[argument] = payload
            return (.ok, [], stop)
        case "del":
            if var old = values.removeValue(forKey: argument) {
                wipe(&old)
            }
            return (.ok, [], stop)
        case "ttl":
            guard isOpen else { return (.closed, [], stop) }
            return (.ok, Array(String(deadline - now).utf8), stop)
        case "lock":
            close()
            return (.ok, [], true)
        default:
            return (.bad, [], stop)
        }
    }
}

func serveClient(_ fd: Int32, _ window: Window) {
    var peerUser = uid_t(0)
    var peerGroup = gid_t(0)
    guard getpeereid(fd, &peerUser, &peerGroup) == 0, peerUser == geteuid() else {
        close(fd)
        return
    }
    setTimeouts(fd, seconds: serverTimeoutSeconds)
    guard var request = readAll(fd, limit: maxMessageBytes) else {
        close(fd)
        return
    }
    let (status, payload, stop) = window.queue.sync {
        window.handle(request, now: time(nil))
    }
    wipe(&request)

    var answer = [UInt8]()
    answer.reserveCapacity(payload.count + 2)
    answer.append(UInt8(ascii: "0") + status.rawValue)
    answer.append(10)
    answer.append(contentsOf: payload)
    _ = writeAll(fd, answer)
    wipe(&answer)
    close(fd)
    if stop {
        exit(0)
    }
}

func serve() -> Never {
    signal(SIGPIPE, SIG_IGN)
    guard makePrivateDirectory(stateDirectory) else {
        warn("cannot make \(stateDirectory) with mode 0700")
        exit(1)
    }
    guard let address = socketAddress(socketPath) else {
        warn("the socket path is too long: \(socketPath)")
        exit(1)
    }
    if let type = fileType(socketPath) {
        guard type == 0o140000 else {
            warn("\(socketPath) is not a socket")
            exit(1)
        }
        if let fd = connectTo(address) {
            close(fd)
            warn("a helper already runs on \(socketPath)")
            exit(1)
        }
        // An old helper stopped and left its socket.
        unlink(socketPath)
    }

    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else {
        warn("cannot make a socket (errno \(errno))")
        exit(1)
    }
    var bindAddress = address
    let oldMask = umask(0o077)
    let bound = withUnsafePointer(to: &bindAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    umask(oldMask)
    guard bound == 0, listen(listener, 16) == 0 else {
        warn("cannot listen on \(socketPath) (errno \(errno))")
        exit(1)
    }
    _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)

    let window = Window()
    let clients = DispatchQueue(label: "op-sa-window.clients", attributes: .concurrent)
    let source = DispatchSource.makeReadSource(fileDescriptor: listener,
                                               queue: DispatchQueue(label: "op-sa-window.accept"))
    source.setEventHandler {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        // A socket from accept() gets O_NONBLOCK from the listener. Remove
        // it, so that the read timeout applies.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        clients.async { serveClient(fd, window) }
    }
    source.resume()
    dispatchMain()
}

// MARK: - Client

func client(_ command: String, _ argument: String, stdin readStdin: Bool, wait: Bool) -> Int32 {
    var body = [UInt8]()
    if readStdin {
        guard let input = readAll(0, limit: maxMessageBytes - 256) else {
            warn("the input is too long")
            return 2
        }
        body = input
    }
    defer { wipe(&body) }
    guard let address = socketAddress(socketPath) else {
        warn("the socket path is too long: \(socketPath)")
        return 3
    }

    // launchd starts a new helper after a lock. `open` waits for it.
    let giveUp = time(nil) + (wait ? openWaitSeconds : 0)
    var connection: Int32? = connectTo(address)
    while connection == nil && time(nil) < giveUp {
        usleep(200_000)
        connection = connectTo(address)
    }
    // No helper runs, so no window is open.
    guard let fd = connection else {
        return Int32(Status.closed.rawValue)
    }
    defer { close(fd) }
    setTimeouts(fd, seconds: clientTimeoutSeconds)

    var request = Array("\(command) \(argument)\n".utf8)
    request.reserveCapacity(request.count + body.count)
    request.append(contentsOf: body)
    defer { wipe(&request) }
    guard writeAll(fd, request) else {
        warn("the helper did not take the request")
        return 3
    }
    shutdown(fd, SHUT_WR)

    guard var answer = readAll(fd, limit: maxMessageBytes), answer.count >= 2, answer[1] == 10,
          let status = Status(rawValue: answer[0] &- UInt8(ascii: "0")) else {
        warn("the helper did not answer")
        return 3
    }
    defer { wipe(&answer) }
    _ = writeAll(1, answer, from: 2)
    return Int32(status.rawValue)
}

// MARK: - Main

func usage() -> Never {
    warn("usage: op-sa-window serve | open SECONDS | get KEY | put KEY | del KEY | ttl | lock")
    exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { usage() }
switch (arguments[1], arguments.count) {
case ("serve", 2):
    serve()
case ("open", 3):
    exit(client("open", arguments[2], stdin: true, wait: true))
case ("put", 3):
    exit(client("put", arguments[2], stdin: true, wait: false))
case ("get", 3), ("del", 3):
    exit(client(arguments[1], arguments[2], stdin: false, wait: false))
case ("ttl", 2), ("lock", 2):
    exit(client(arguments[1], "", stdin: false, wait: false))
default:
    usage()
}
