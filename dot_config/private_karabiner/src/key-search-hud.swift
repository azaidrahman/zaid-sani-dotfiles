// key-search-hud: fuzzy-searchable reference of all Karabiner layer bindings,
// with a keyboard map mode. Opened by hyper+shift+/.
//
// Usage: key-search-hud <keymap-index.tsv> [fkey-index.tsv]
// The TSVs come from scripts/generate.py. The key index has columns: layer, trigger, key, label, action.
// The F-key index has columns: fkey, mods, layer, key, label.
//
// Map mode (opens first): one view per layer, and an F-keys view. Left and right arrows switch views.
//   In the F-keys view, up and down arrows pick an F-key.
//   The / key or the search button opens search.
// Search mode: type to filter. Up and down scroll. Deleting all the text returns to the map.
// Esc (or click away) closes the HUD. The map reloads when the TSV changes.
import AppKit

struct Entry {
    let layer: String
    let trigger: String
    let key: String
    let label: String
    let action: String
    var haystack: String { "\(layer) \(trigger) \(key) \(label) \(action)".lowercased() }
}

guard CommandLine.arguments.count > 1 else {
    fputs("Usage: key-search-hud <keymap-index.tsv> [fkey-index.tsv]\n", stderr)
    exit(1)
}

let filePath = (CommandLine.arguments[1] as NSString).expandingTildeInPath
let fkeyPath = CommandLine.arguments.count > 2
    ? (CommandLine.arguments[2] as NSString).expandingTildeInPath : ""
guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
    fputs("Cannot read \(filePath)\n", stderr)
    exit(1)
}

let entries: [Entry] = content.components(separatedBy: .newlines).compactMap { line in
    let parts = line.components(separatedBy: "\t")
    guard parts.count >= 3 else { return nil }
    return Entry(
        layer: parts[0],
        trigger: parts.count > 1 ? parts[1] : "",
        key: parts.count > 2 ? parts[2] : "",
        label: parts.count > 3 ? parts[3] : "",
        action: parts.count > 4 ? parts[4] : ""
    )
}

// Fuzzy subsequence match. Returns a score (higher = better) or nil.
func fuzzyScore(_ query: String, _ text: String) -> Int? {
    if query.isEmpty { return 0 }
    // Whole-substring match ranks above scattered subsequences
    if let r = text.range(of: query) {
        return 1000 - text.distance(from: text.startIndex, to: r.lowerBound)
    }
    var score = 0
    var qi = query.startIndex
    var prevMatched = false
    var prevChar: Character = " "
    for ch in text {
        if qi < query.endIndex && ch == query[qi] {
            score += prevMatched ? 3 : 1
            if prevChar == " " { score += 2 }
            qi = query.index(after: qi)
            prevMatched = true
        } else {
            prevMatched = false
        }
        prevChar = ch
    }
    return qi == query.endIndex ? score : nil
}

func filtered(_ query: String) -> [Entry] {
    let q = query.lowercased().trimmingCharacters(in: .whitespaces)
    if q.isEmpty { return entries }
    return entries
        .compactMap { e in fuzzyScore(q, e.haystack).map { (e, $0) } }
        .sorted { $0.1 > $1.1 }
        .map { $0.0 }
}

// -- UI ------------------------------------------------------------------------

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// System font, to match the Karabiner notification overlays (the / tooltips)
let fontSize: CGFloat = 13.5
let rowFont = NSFont.systemFont(ofSize: fontSize)
let keyFont = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
let triggerColor = NSColor(red: 1.0, green: 0.75, blue: 0.35, alpha: 1.0)
let keyColor = NSColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 1.0)
let labelColor = NSColor.white
let actionColor = NSColor(white: 1, alpha: 0.45)

let visibleRows = 18
let lineHeight: CGFloat = 24
let padding: CGFloat = 16
let panelWidth: CGFloat = 680
let searchHeight: CGFloat = 34
let listHeight = CGFloat(visibleRows) * lineHeight
let panelHeight = listHeight + searchHeight + padding * 2 + 8

// Column x-offsets inside the list (system font is proportional,
// so alignment comes from fixed positions, not space padding)
let colTrigger: CGFloat = 0
let colKey: CGFloat = 62
let colLabel: CGFloat = 156
let colAction: CGFloat = 356

class KeyPanel: NSPanel {
    var didBecomeKey = false
    override var canBecomeKey: Bool { true }
    override func becomeKey() {
        super.becomeKey()
        didBecomeKey = true
    }
    // Close when focus moves elsewhere — but only once the panel actually
    // held focus, so an activation race at launch cannot insta-close it.
    override func resignKey() {
        super.resignKey()
        if didBecomeKey {
            NSApp.terminate(nil)
        }
    }
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// -- Keyboard map mode ---------------------------------------------------------

struct Binding {
    let mods: String
    let base: String
    let label: String
    let action: String
}

struct Layer {
    var trigger = ""
    var entries: [Binding] = []              // every row of the layer
    var bindings: [String: [Binding]] = [:]  // board key -> bindings
}

enum ViewKind { case board, list, modifier, fkey }

struct LayerSpec {
    let id: String
    let title: String
    let kind: ViewKind
}

// Layer ids as they appear in the TSV, with the view each one uses
let layerSpecs = [
    LayerSpec(id: "app", title: "App", kind: .board),
    LayerSpec(id: "workspace", title: "Workspace", kind: .board),
    LayerSpec(id: "fkey", title: "F-keys", kind: .fkey),
    LayerSpec(id: "l1", title: "l1", kind: .board),
    LayerSpec(id: "l2", title: "l2", kind: .board),
    LayerSpec(id: "l3", title: "l3", kind: .board),
    LayerSpec(id: "hyper", title: "Hyper", kind: .modifier),
]

// The keys drawn on the board, row by row
let gridRows: [[String]] = [
    ["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="],
    ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "[", "]", "\\"],
    ["a", "s", "d", "f", "g", "h", "j", "k", "l", ";", "'"],
    ["z", "x", "c", "v", "b", "n", "m", ",", ".", "/"],
]
let spaceKey = "spacebar"
let gridKeys = Set(gridRows.flatMap { $0 } + [spaceKey])

// Left indent of each row, in key units, as on a real keyboard
let rowIndent: [CGFloat] = [0, 0.5, 0.75, 1.25]

// Keys in QWERTY reading order, used to sort lists
let qwertyOrder = Array("`1234567890-=qwertyuiop[]\\asdfghjkl;'zxcvbnm,./")

// Modifier glyphs that prefix a key in the TSV, e.g. "⇧w" or "⌘spacebar"
let modGlyphs: Set<Character> = ["⇧", "⌘", "⌥", "⌃", "⇪"]

func splitKey(_ raw: String) -> (mods: String, base: String) {
    var mods = ""
    var rest = Substring(raw)
    while let c = rest.first, modGlyphs.contains(c) {
        mods.append(c)
        rest = rest.dropFirst()
    }
    return (mods, String(rest))
}

// Board keys that hold a layer, from its trigger glyphs, e.g. "⇧⌥R" or "⇪"
func triggerKeys(_ trigger: String) -> Set<String> {
    var ids = Set<String>()
    let chars = Array(trigger)
    var i = 0
    while i < chars.count {
        switch chars[i] {
        case "⇧": ids.insert("Lshift")
        case "⌘": ids.insert("Lcmd")
        case "⌃": ids.insert("Lctrl")
        case "⇪": ids.insert("caps")
        case "⌥":
            if i + 1 < chars.count {
                ids.insert(chars[i + 1] == "R" ? "Ropt" : "Lopt")
                i += 1
            }
        default: break
        }
        i += 1
    }
    return ids
}

// Board keys for the modifiers of a hyper chip. A chip has no side, so both sides light.
func chipKeys(_ mods: String) -> Set<String> {
    var ids = Set<String>()
    for c in mods {
        switch c {
        case "⇧": ids.formUnion(["Lshift", "Rshift"])
        case "⌘": ids.insert("Lcmd")
        case "⌃": ids.insert("Lctrl")
        case "⌥": ids.formUnion(["Lopt", "Ropt"])
        default: break
        }
    }
    return ids
}

func qwertyIndex(_ key: String) -> Int {
    guard key.count == 1, let c = key.first, let i = qwertyOrder.firstIndex(of: c) else { return 999 }
    return i
}

func loadLayers(_ path: String) -> [String: Layer] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
    let ids = layerSpecs.map { $0.id }
    var layers: [String: Layer] = [:]
    for line in text.components(separatedBy: .newlines) {
        let parts = line.components(separatedBy: "\t")
        guard parts.count >= 3, ids.contains(parts[0]) else { continue }
        var layer = layers[parts[0]] ?? Layer()
        if layer.trigger.isEmpty { layer.trigger = parts[1] }
        let (mods, base) = splitKey(parts[2])
        let binding = Binding(
            mods: mods,
            base: base,
            label: parts.count > 3 ? parts[3] : "",
            action: parts.count > 4 ? parts[4] : "")
        layer.entries.append(binding)
        if gridKeys.contains(base) {
            layer.bindings[base, default: []].append(binding)
        }
        layers[parts[0]] = layer
    }
    return layers
}

// One F-key binding: a layer key that sends this F-key with these modifiers
struct FKeyBinding {
    let fkey: String   // e.g. "F16"
    let mods: String   // modifier glyphs, e.g. "⌘⌥⇧"
    let layer: String  // "l1", "l2" or "l3"
    let key: String    // the key on the board, e.g. "o"
    let label: String  // e.g. "1p"
}

// F-keys that the layers send. F14 and F15 are left out, as they are the brightness keys.
let fkeyNames = ["F13", "F16", "F17", "F18", "F19", "F20"]

// Rows per column in the F-keys view. Two columns, so 16 bindings fit.
let fkeyRowsPerColumn = 8

// The four modifiers, in the order of the keycaps. Left and right sides share one keycap.
let modKeycaps: [(glyph: String, name: String)] = [("⌘", "cmd"), ("⌃", "ctrl"), ("⌥", "opt"), ("⇧", "shift")]

func loadFKeys(_ path: String) -> [FKeyBinding] {
    guard !path.isEmpty, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return text.components(separatedBy: .newlines).compactMap { line in
        let parts = line.components(separatedBy: "\t")
        guard parts.count >= 5 else { return nil }
        return FKeyBinding(fkey: parts[0], mods: parts[1], layer: parts[2], key: parts[3], label: parts[4])
    }
}

func modificationDate(_ path: String) -> Date? {
    guard !path.isEmpty else { return nil }
    return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}

let mapHeight: CGFloat = 390
let margin: CGFloat = 24
let unit: CGFloat = 40      // distance between key origins
let keySize: CGFloat = 36
let boardTop: CGFloat = 112 // top of the first board row
let listTop: CGFloat = 84   // top of the list and the modifier chips

let boundColor = NSColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 1.0)
let modifiedColor = NSColor(red: 1.0, green: 0.75, blue: 0.35, alpha: 1.0)
let freeColor = NSColor(red: 0.45, green: 0.9, blue: 0.55, alpha: 1.0)
let selectedColor = NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1.0)  // a clicked key with bindings
let unusedColor = NSColor(white: 0.5, alpha: 1.0)                          // a clicked key with none
let dimColor = NSColor(white: 1, alpha: 0.45)
let ink = NSColor(white: 0.08, alpha: 1.0)

func drawText(_ s: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular,
              color: NSColor, align: NSTextAlignment = .left) {
    let style = NSMutableParagraphStyle()
    style.alignment = align
    style.lineBreakMode = .byTruncatingTail
    NSAttributedString(string: s, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: style,
    ]).draw(in: rect)
}

class KeymapView: NSView {
    let filePath: String
    let fkeyPath: String
    var layers: [String: Layer] = [:]
    var lastModified: Date?
    var fkeys: [FKeyBinding] = []
    var fkeyLastModified: Date?
    var selectedFKeyIndex = 0  // chip picked in the F-keys view
    var fkeyChipRects: [(name: String, rect: NSRect)] = []
    var current = 0
    var hovered: String?
    var selectedKey: String?  // key clicked on the board, red if bound, grey if not
    let searchRect = NSRect(x: panelWidth - margin - 96, y: 48, width: 96, height: 24)
    var selectedMods = ""     // chip picked in the hyper view
    var keyRects: [(key: String, rect: NSRect)] = []
    var fixedRects: [(id: String, label: String, rect: NSRect)] = []  // labels only: modifiers, Tab, Caps
    var tabRects: [NSRect] = []
    var chipRects: [(mods: String, rect: NSRect)] = []
    var stepRects: [(delta: Int, rect: NSRect)] = []  // up and down buttons for the chips
    var onSearch: (() -> Void)?  // called by the / key and by the search button

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var spec: LayerSpec { layerSpecs[current] }
    var currentLayer: Layer { layers[spec.id] ?? Layer() }

    init(filePath: String, fkeyPath: String) {
        self.filePath = filePath
        self.fkeyPath = fkeyPath
        super.init(frame: NSRect(x: 0, y: 0, width: panelWidth, height: mapHeight))
        layoutKeys()
        layoutTabs()
        reloadIfChanged()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.reloadIfChanged()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func layoutKeys() {
        let originX = (panelWidth - 13 * unit) / 2
        for (r, row) in gridRows.enumerated() {
            for (c, key) in row.enumerated() {
                let x = originX + rowIndent[r] * unit + CGFloat(c) * unit
                let y = boardTop + CGFloat(r) * unit
                keyRects.append((key: key, rect: NSRect(x: x, y: y, width: keySize, height: keySize)))
            }
        }
        // Bottom row, as on the real keyboard. Only space takes bindings.
        // The other keys are labels, so they are not in keyRects.
        let bottomY = boardTop + 4 * unit
        let bottom: [(name: String, x: CGFloat, w: CGFloat)] = [
            ("Lcmd", 0, 1.25), ("Lctrl", 1.25, 1.25), ("Lopt", 2.5, 1.25),
            (spaceKey, 3.75, 6), ("Ropt", 9.75, 1.25), ("", 11, 1), ("Fn", 12, 1),
        ]
        for key in bottom where !key.name.isEmpty {
            let rect = NSRect(x: originX + key.x * unit, y: bottomY,
                              width: key.w * unit - (unit - keySize), height: keySize)
            if key.name == spaceKey {
                keyRects.append((key: spaceKey, rect: rect))
            } else {
                fixedRects.append((id: key.name, label: key.name, rect: rect))
            }
        }
        // Tab and Caps sit left of the grid. Each one is a label only.
        fixedRects.append((id: "tab", label: "Ctrl/Tab", rect: NSRect(x: originX - unit, y: boardTop + unit,
                                                                       width: 1.5 * unit - (unit - keySize), height: keySize)))
        fixedRects.append((id: "caps", label: "Hyper/Esc", rect: NSRect(x: originX - unit, y: boardTop + 2 * unit,
                                                                        width: 1.75 * unit - (unit - keySize), height: keySize)))
        // Shift keys end the z row, as on the real keyboard
        fixedRects.append((id: "Lshift", label: "Lshift", rect: NSRect(x: originX - unit, y: boardTop + 3 * unit,
                                                                       width: 2.25 * unit - (unit - keySize), height: keySize)))
        fixedRects.append((id: "Rshift", label: "Rshift", rect: NSRect(x: originX + 11.25 * unit, y: boardTop + 3 * unit,
                                                                       width: 1.75 * unit - (unit - keySize), height: keySize)))
    }

    func layoutTabs() {
        let gap: CGFloat = 6
        // One tab per layer
        let count = CGFloat(layerSpecs.count)
        let width = (panelWidth - margin * 2 - gap * (count - 1)) / count
        for i in 0..<Int(count) {
            let x = margin + CGFloat(i) * (width + gap)
            tabRects.append(NSRect(x: x, y: 16, width: width, height: 28))
        }
    }

    // Reload only when the file changed, so edits show up without reopening
    func reloadIfChanged() {
        let modified = modificationDate(filePath)
        let fkeyModified = modificationDate(fkeyPath)
        guard modified != lastModified || fkeyModified != fkeyLastModified else { return }
        lastModified = modified
        fkeyLastModified = fkeyModified
        layers = loadLayers(filePath)
        fkeys = loadFKeys(fkeyPath)
        needsDisplay = true
    }

    func setLayer(_ index: Int) {
        current = min(max(index, 0), layerSpecs.count - 1)
        hovered = nil
        selectedKey = nil
        selectedMods = ""
        needsDisplay = true
    }

    // Bindings that the board shows for one key. The hyper view filters by modifier set.
    func boardBindings(_ key: String) -> [Binding] {
        let bs = currentLayer.bindings[key] ?? []
        guard spec.kind == .modifier else { return bs }
        return bs.filter { $0.mods == selectedMods }
    }

    // Modifier sets that have at least one hyper binding, plain first
    func modifierSets() -> [String] {
        let sets = Set(currentLayer.entries.map { $0.mods })
        return sets.sorted { ($0.count, $0) < ($1.count, $1) }
    }

    // Move the chip selection back or forward. It stops at either end.
    func cycleChip(_ delta: Int) {
        let sets = modifierSets()
        guard !sets.isEmpty else { return }
        let next = (sets.firstIndex(of: selectedMods) ?? 0) + delta
        guard next >= 0 && next < sets.count else { return }
        selectedMods = sets[next]
        hovered = nil
        needsDisplay = true
    }

    // The F-keys view shows bindings, not keys: one row per binding of the picked F-key
    func fkeyName() -> String { fkeyNames[selectedFKeyIndex] }

    func fkeyRows() -> [FKeyBinding] {
        fkeys.filter { $0.fkey == fkeyName() }.sorted {
            ($0.mods.count, $0.layer, qwertyIndex($0.key)) < ($1.mods.count, $1.layer, qwertyIndex($1.key))
        }
    }

    // Move the F-key chip selection. It stops at either end, as the modifier chips do.
    func cycleFKey(_ delta: Int) {
        let next = selectedFKeyIndex + delta
        guard next >= 0 && next < fkeyNames.count else { return }
        selectedFKeyIndex = next
        needsDisplay = true
    }

    // The up and down buttons and arrows drive whichever view has chips
    func stepChip(_ delta: Int) {
        if spec.kind == .fkey {
            cycleFKey(delta)
        } else {
            cycleChip(delta)
        }
    }

    // Only the board views draw keys, so only they react to the keys on the board
    var hasBoard: Bool { spec.kind == .board || spec.kind == .modifier }

    // -- Events ----------------------------------------------------------------

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard hasBoard else { return }
        let p = convert(event.locationInWindow, from: nil)
        let hit = keyRects.first(where: { $0.rect.contains(p) })?.key
        if hit != hovered {
            hovered = hit
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if searchRect.contains(p) {
            onSearch?()
        } else if let i = tabRects.firstIndex(where: { $0.contains(p) }) {
            setLayer(i)
        } else if spec.kind == .modifier, let chip = chipRects.first(where: { $0.rect.contains(p) }) {
            selectedMods = chip.mods
            hovered = nil
            needsDisplay = true
        } else if spec.kind == .fkey, let i = fkeyChipRects.firstIndex(where: { $0.rect.contains(p) }) {
            selectedFKeyIndex = i
            needsDisplay = true
        } else if spec.kind == .modifier || spec.kind == .fkey,
                  let step = stepRects.first(where: { $0.rect.contains(p) }) {
            stepChip(step.delta)
        } else if hasBoard, let key = keyRects.first(where: { $0.rect.contains(p) })?.key {
            // Click a key to mark it red. Click it again to clear it.
            selectedKey = selectedKey == key ? nil : key
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "/" { onSearch?(); return }
        switch event.keyCode {
        case 53: NSApp.terminate(nil)                              // esc
        case 125 where spec.kind == .modifier || spec.kind == .fkey: stepChip(1)   // down arrow
        case 126 where spec.kind == .modifier || spec.kind == .fkey: stepChip(-1)  // up arrow
        // Left and right wrap around the tabs: left of App is Hyper, right of Hyper is App
        case 123: setLayer((current - 1 + layerSpecs.count) % layerSpecs.count)   // left arrow
        case 124: setLayer((current + 1) % layerSpecs.count)                      // right arrow
        default:
            // A key on the board selects that key, as a click does
            if hasBoard, let typed = event.charactersIgnoringModifiers?.lowercased(), typed.count == 1 {
                let key = typed == " " ? spaceKey : typed
                if keyRects.contains(where: { $0.key == key }) {
                    selectedKey = key
                    needsDisplay = true
                    return
                }
            }
            super.keyDown(with: event)
        }
    }

    // -- Drawing ---------------------------------------------------------------

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.1, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        drawTabs()
        drawInfo()
        drawSearchButton()
        switch spec.kind {
        case .board:
            drawBoard()
            drawFixedKeys()
            drawBoardStatus()
        case .list:
            drawList()
            drawListStatus()
        case .modifier:
            drawChips()
            drawBoard()
            drawFixedKeys()
            drawBoardStatus()
        case .fkey:
            drawFKeyChips()
            drawFKeyTable()
            drawFKeyStatus()
        }
    }

    func drawTabs() {
        for (i, r) in tabRects.enumerated() {
            let on = i == current
            let title = layerSpecs[i].title
            (on ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 1, alpha: 0.06)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
            drawText(title, in: NSRect(x: r.minX, y: r.minY + 6, width: r.width, height: 18),
                     size: 12.5, weight: on ? .semibold : .regular,
                     color: on ? .white : dimColor, align: .center)
        }
    }

    func drawInfo() {
        let layer = currentLayer
        let text: String
        switch spec.kind {
        case .board:
            text = "held \(layer.trigger)   ·   \(boundCount()) bound   ·   \(freeCount()) free"
        case .list:
            text = "held \(layer.trigger)   ·   \(layer.entries.count) bindings"
        case .fkey:
            text = "Virtual keys: the layers send these F-keys, and Keyboard Maestro or Alfred listens for them."
        case .modifier:
            let name = selectedMods.isEmpty ? "no modifier" : selectedMods
            text = "held \(layer.trigger)   ·   \(name)   ·   \(boundCount()) bound   ·   \(freeCount()) free"
        }
        drawText(text, in: NSRect(x: margin, y: 54, width: panelWidth - margin * 2, height: 18),
                 size: 12, color: .white)
    }

    // The button that opens search, the same as the / key
    func drawSearchButton() {
        NSColor(white: 1, alpha: 0.12).setFill()
        NSBezierPath(roundedRect: searchRect, xRadius: 6, yRadius: 6).fill()
        drawText("/ search", in: NSRect(x: searchRect.minX, y: searchRect.minY + 4, width: searchRect.width, height: 18),
                 size: 12, color: .white, align: .center)
    }

    func boundCount() -> Int {
        gridKeys.filter { !boardBindings($0).isEmpty }.count
    }

    func freeCount() -> Int {
        gridKeys.count - boundCount()
    }

    // One chip. The chip that is on is brighter and bold.
    func drawChip(_ title: String, at rect: NSRect, on: Bool) {
        (on ? NSColor(white: 1, alpha: 0.2) : NSColor(white: 1, alpha: 0.06)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        drawText(title, in: NSRect(x: rect.minX, y: rect.minY + 4, width: rect.width, height: 16),
                 size: 12, weight: on ? .semibold : .regular, color: on ? .white : dimColor, align: .center)
    }

    // Up and down buttons at the right end of the chip row
    func drawStepButtons() {
        stepRects = [(delta: -1, rect: NSRect(x: panelWidth - margin - 58, y: listTop, width: 26, height: 22)),
                     (delta: 1, rect: NSRect(x: panelWidth - margin - 28, y: listTop, width: 26, height: 22))]
        for (step, label) in zip(stepRects, ["▲", "▼"]) {
            NSColor(white: 1, alpha: 0.06).setFill()
            NSBezierPath(roundedRect: step.rect, xRadius: 6, yRadius: 6).fill()
            drawText(label, in: NSRect(x: step.rect.minX, y: step.rect.minY + 3, width: step.rect.width, height: 16),
                     size: 11, color: .white, align: .center)
        }
    }

    // Chips that pick the modifier set shown on the hyper board
    func drawChips() {
        chipRects = []
        var x = margin
        for mods in modifierSets() {
            let width: CGFloat = 70
            let rect = NSRect(x: x, y: listTop, width: width, height: 22)
            chipRects.append((mods: mods, rect: rect))
            drawChip(mods.isEmpty ? "plain" : mods, at: rect, on: mods == selectedMods)
            x += width + 6
        }
        drawStepButtons()
    }

    // Chips that pick the F-key shown in the F-keys view
    func drawFKeyChips() {
        fkeyChipRects = []
        var x = margin
        for (i, name) in fkeyNames.enumerated() {
            let width: CGFloat = 70
            let rect = NSRect(x: x, y: listTop, width: width, height: 22)
            fkeyChipRects.append((name: name, rect: rect))
            drawChip(name, at: rect, on: i == selectedFKeyIndex)
            x += width + 6
        }
        drawStepButtons()
    }

    // A modifier keycap. It is lit when the output uses that modifier.
    func drawKeycap(_ glyph: String, in rect: NSRect, lit: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        if lit {
            boundColor.setFill()
            path.fill()
        } else {
            path.lineWidth = 1
            NSColor(white: 1, alpha: 0.25).setStroke()
            path.stroke()
        }
        drawText(glyph, in: NSRect(x: rect.minX, y: rect.minY + 1, width: rect.width, height: 16),
                 size: 12, weight: .semibold, color: lit ? ink : dimColor, align: .center)
    }

    // The F-keys view: one row per binding of the picked F-key. Each row has four
    // modifier keycaps, then the layer key that sends it. Left and right share one keycap.
    func drawFKeyTable() {
        let rows = fkeyRows()
        let columnGap: CGFloat = 12
        let columnWidth = (panelWidth - margin * 2 - columnGap) / 2
        let headerY: CGFloat = 112
        let rowsTop: CGFloat = 132
        let rowHeight: CGFloat = 22
        let capWidth: CGFloat = 40
        let capStep: CGFloat = 46
        let labelX = CGFloat(modKeycaps.count) * capStep + 4

        // The second column gets its header only when it has rows
        let columns = rows.count > fkeyRowsPerColumn ? 2 : 1
        for column in 0..<columns {
            let x = margin + CGFloat(column) * (columnWidth + columnGap)
            for (c, cap) in modKeycaps.enumerated() {
                drawText(cap.name, in: NSRect(x: x + CGFloat(c) * capStep, y: headerY, width: capWidth, height: 16),
                         size: 10, color: dimColor, align: .center)
            }
            drawText("binding", in: NSRect(x: x + labelX, y: headerY, width: columnWidth - labelX, height: 16),
                     size: 10, color: dimColor)
        }

        if rows.isEmpty {
            drawText("No layer key sends \(fkeyName()).",
                     in: NSRect(x: margin, y: rowsTop + 3, width: panelWidth - margin * 2, height: 18),
                     size: 12, color: dimColor)
            return
        }
        for (i, b) in rows.prefix(fkeyRowsPerColumn * 2).enumerated() {
            let column = CGFloat(i / fkeyRowsPerColumn)
            let row = CGFloat(i % fkeyRowsPerColumn)
            let x = margin + column * (columnWidth + columnGap)
            let y = rowsTop + row * rowHeight
            for (c, cap) in modKeycaps.enumerated() {
                let rect = NSRect(x: x + CGFloat(c) * capStep, y: y + 1, width: capWidth, height: 18)
                drawKeycap(cap.glyph, in: rect, lit: b.mods.contains(cap.glyph))
            }
            drawText("\(b.layer) \(b.key) \(b.label)",
                     in: NSRect(x: x + labelX, y: y + 3, width: columnWidth - labelX, height: 18),
                     size: 12, color: .white)
        }
    }

    func drawFKeyStatus() {
        let rows = fkeyRows()
        let combos = 1 << modKeycaps.count  // every subset of the four modifiers
        let used = Set(rows.map { $0.mods }).count
        var title = "\(fkeyName()) · \(rows.count) bindings · \(combos - used) of \(combos) combos free"
        let hidden = rows.count - fkeyRowsPerColumn * 2
        if hidden > 0 {
            title += " · \(hidden) not shown"
        }
        drawStatusLines(title: title, detail: "", hint: "▲ ▼ cycle F-keys · ← → layers · / to search")
    }

    func drawBoard() {
        for (key, rect) in keyRects {
            let bs = boardBindings(key)
            let isHover = key == hovered
            let isSelected = key == selectedKey
            let name = key == spaceKey ? "space" : key
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)

            if bs.isEmpty && !isSelected {
                path.lineWidth = isHover ? 2 : 1
                freeColor.withAlphaComponent(isHover ? 0.95 : 0.45).setStroke()
                path.stroke()
                drawText(name, in: NSRect(x: rect.minX, y: rect.minY + 9, width: rect.width, height: 18),
                         size: 13, weight: .medium, color: dimColor, align: .center)
            } else {
                let hasBare = bs.contains(where: { $0.mods.isEmpty })
                let fill = isSelected ? (bs.isEmpty ? unusedColor : selectedColor)
                    : (hasBare ? boundColor : modifiedColor)
                fill.withAlphaComponent(isHover ? 1 : 0.85).setFill()
                path.fill()
                let shown = bs.first(where: { $0.mods.isEmpty }) ?? bs.first
                // A letter with a shift binding shows its capital too: w/W, or W alone
                let upper = key.count == 1 && key.first?.isLetter == true ? key.uppercased() : ""
                let hasShift = bs.contains(where: { $0.mods.contains("⇧") }) && !upper.isEmpty
                let cap = !hasShift ? name : (hasBare ? "\(name)/\(upper)" : upper)
                drawText(cap, in: NSRect(x: rect.minX, y: rect.minY + 2, width: rect.width, height: 16),
                         size: 12, weight: .semibold, color: isSelected ? .white : ink, align: .center)
                if let shown = shown {
                    drawText(String(shown.label.prefix(7)),
                             in: NSRect(x: rect.minX, y: rect.minY + 19, width: rect.width, height: 14),
                             size: 8, color: isSelected ? .white : ink, align: .center)
                }
            }
            // Hover outline, drawn last so the fill does not cover it
            if isHover {
                path.lineWidth = 2
                NSColor.white.setStroke()
                path.stroke()
            }
        }
    }

    // Keys that hold the current layer light up green
    func drawFixedKeys() {
        let held = triggerKeys(currentLayer.trigger)
            .union(spec.kind == .modifier ? chipKeys(selectedMods) : [])
        for (id, label, rect) in fixedRects {
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            if held.contains(id) {
                freeColor.setFill()
                path.fill()
                drawText(label, in: NSRect(x: rect.minX, y: rect.minY + 9, width: rect.width, height: 18),
                         size: 10, weight: .semibold, color: ink, align: .center)
            } else {
                path.lineWidth = 1
                NSColor(white: 1, alpha: 0.25).setStroke()
                path.stroke()
                drawText(label, in: NSRect(x: rect.minX, y: rect.minY + 9, width: rect.width, height: 18),
                         size: 10, color: dimColor, align: .center)
            }
        }
    }

    func drawBoardStatus() {
        var title = "Hover a key to see its bindings."
        var detail = ""
        let otherKeys = currentLayer.entries.filter { !gridKeys.contains($0.base) }.map { $0.mods + $0.base }
        if !otherKeys.isEmpty {
            detail = "Also bound: " + otherKeys.joined(separator: "  ")
        }

        if let key = hovered ?? selectedKey {
            let name = key == spaceKey ? "space" : key
            let bs = boardBindings(key)
            if !bs.isEmpty {
                func line(_ list: [Binding]) -> String {
                    list.map { "\($0.mods)\(name)  \($0.label)  →  \($0.action)" }.joined(separator: "   ·   ")
                }
                // Plain bindings on the first line. Capitals (shift) go on a second line.
                let plain = bs.filter { !$0.mods.contains("⇧") }
                let upper = bs.filter { $0.mods.contains("⇧") }
                title = plain.isEmpty ? line(upper) : line(plain)
                detail = plain.isEmpty ? "" : line(upper)
            } else {
                title = "\(name) is free in \(spec.title)."
                detail = ""
            }
        }
        drawStatusLines(title: title, detail: detail,
                        hint: spec.kind == .modifier
                            ? "▲ ▼ cycle chips · ← → layers · / to search"
                            : "blue bound · amber modifier only · green free · ← → layers · / to search")
    }

    // The list view: every binding in QWERTY order, two columns
    func drawList() {
        let sorted = currentLayer.entries.sorted {
            (qwertyIndex($0.base), $0.mods) < (qwertyIndex($1.base), $1.mods)
        }
        let perColumn = 9
        let columnWidth = (panelWidth - margin * 2) / 2
        let rowHeight: CGFloat = 22
        for (i, b) in sorted.enumerated() {
            let column = CGFloat(i / perColumn)
            let row = CGFloat(i % perColumn)
            let x = margin + column * columnWidth
            let y = listTop + row * rowHeight
            let name = b.base == spaceKey ? "space" : b.base
            let keyTint = b.mods.isEmpty ? boundColor : modifiedColor
            drawText(b.mods + name, in: NSRect(x: x, y: y + 3, width: 52, height: 18),
                     size: 12, weight: .semibold, color: keyTint)
            drawText(b.label, in: NSRect(x: x + 56, y: y + 3, width: 96, height: 18),
                     size: 12, color: .white)
            drawText(b.action, in: NSRect(x: x + 156, y: y + 4, width: columnWidth - 166, height: 18),
                     size: 11, color: dimColor)
        }
    }

    func drawListStatus() {
        let bound = Set(currentLayer.entries.map { $0.base })
        let free = qwertyOrder.map { String($0) }
            .filter { gridKeys.contains($0) && !bound.contains($0) }
        let title = "\(currentLayer.entries.count) bindings · \(free.count) free keys"
        let detail = "free: " + free.joined(separator: "  ")
        drawStatusLines(title: title, detail: detail,
                        hint: "← → layers · → on Hyper opens search · esc closes")
    }

    func drawStatusLines(title: String, detail: String, hint: String) {
        let width = panelWidth - margin * 2
        drawText(title, in: NSRect(x: margin, y: 322, width: width, height: 18),
                 size: 13, weight: .medium, color: .white)
        drawText(detail, in: NSRect(x: margin, y: 344, width: width, height: 18),
                 size: 13, weight: .medium, color: .white)
        drawText(hint, in: NSRect(x: margin, y: 368, width: width, height: 14),
                 size: 10, color: dimColor)
    }
}

let rootView = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
rootView.appearance = NSAppearance(named: .darkAqua)
rootView.wantsLayer = true
rootView.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.95).cgColor
rootView.layer?.cornerRadius = 14

let searchField = NSTextField(frame: NSRect(
    x: padding, y: panelHeight - padding - searchHeight,
    width: panelWidth - padding * 2, height: searchHeight))
searchField.font = NSFont.systemFont(ofSize: 16)
searchField.textColor = .white
searchField.backgroundColor = NSColor(white: 0.2, alpha: 1.0)
searchField.isBordered = false
searchField.focusRingType = .none
searchField.wantsLayer = true
searchField.layer?.cornerRadius = 8
searchField.placeholderString = "search keys…  (empty returns to the map)"
rootView.addSubview(searchField)

let scrollView = NSScrollView(frame: NSRect(
    x: padding, y: padding,
    width: panelWidth - padding * 2,
    height: listHeight))
scrollView.drawsBackground = false
scrollView.hasVerticalScroller = true
scrollView.scrollerStyle = .overlay
scrollView.autohidesScrollers = true
scrollView.verticalScroller?.knobStyle = .light
scrollView.verticalScrollElasticity = .none

let docView = FlippedView(frame: NSRect(x: 0, y: 0, width: scrollView.frame.width, height: 0))
scrollView.documentView = docView
rootView.addSubview(scrollView)

func addLabel(_ text: String, font: NSFont, color: NSColor,
              x: CGFloat, y: CGFloat, width: CGFloat) {
    let l = NSTextField(labelWithString: text)
    l.font = font
    l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    l.frame = NSRect(x: x, y: y + 3, width: width, height: lineHeight - 4)
    docView.addSubview(l)
}

func render(_ query: String) {
    docView.subviews.forEach { $0.removeFromSuperview() }
    let matches = filtered(query)
    docView.setFrameSize(NSSize(
        width: scrollView.frame.width,
        height: max(CGFloat(matches.count) * lineHeight, listHeight)))

    let listWidth = scrollView.frame.width
    for (i, e) in matches.enumerated() {
        let y = CGFloat(i) * lineHeight
        addLabel(e.trigger, font: rowFont, color: triggerColor, x: colTrigger, y: y, width: colKey - colTrigger - 6)
        addLabel(e.key, font: keyFont, color: keyColor, x: colKey, y: y, width: colLabel - colKey - 6)
        addLabel(e.label, font: rowFont, color: labelColor, x: colLabel, y: y, width: colAction - colLabel - 6)
        addLabel(e.action, font: rowFont, color: actionColor, x: colAction, y: y, width: listWidth - colAction)
    }

    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)
}

func scrollBy(_ dy: CGFloat) {
    let clip = scrollView.contentView
    let maxY = max(0, (docView.frame.height) - clip.bounds.height)
    var y = clip.bounds.origin.y + dy
    y = min(max(0, y), maxY)
    clip.scroll(to: NSPoint(x: 0, y: y))
    scrollView.reflectScrolledClipView(clip)
}

class SearchDelegate: NSObject, NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        // Deleting all the text returns to the map
        if searchField.stringValue.isEmpty {
            returnToMap()
        } else {
            render(searchField.stringValue)
        }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            // Esc clears the search and returns to the map. Esc on the map closes the HUD.
            searchField.stringValue = ""
            returnToMap()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            NSApp.terminate(nil)
            return true
        case #selector(NSResponder.moveDown(_:)):
            scrollBy(lineHeight)
            return true
        case #selector(NSResponder.moveUp(_:)):
            scrollBy(-lineHeight)
            return true
        case #selector(NSResponder.scrollPageDown(_:)):
            scrollBy(listHeight)
            return true
        case #selector(NSResponder.scrollPageUp(_:)):
            scrollBy(-listHeight)
            return true
        default:
            return false
        }
    }
}
let delegate = SearchDelegate()
searchField.delegate = delegate

let panel = KeyPanel(
    contentRect: rootView.frame,
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
panel.isOpaque = false
panel.backgroundColor = .clear
panel.level = .floating
panel.hasShadow = true
panel.contentView = rootView
panel.acceptsMouseMovedEvents = true

if let screen = NSScreen.main {
    let sf = screen.frame
    panel.setFrameOrigin(NSPoint(
        x: sf.midX - panel.frame.width / 2,
        y: sf.midY - panel.frame.height / 2
    ))
}

// Shown at launch, until the keyboard map is built. The window opens at once.
let loadingView = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: mapHeight))
loadingView.wantsLayer = true
loadingView.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.95).cgColor
loadingView.layer?.cornerRadius = 14
let loadingLabel = NSTextField(labelWithString: "Opening key search…")
loadingLabel.font = NSFont.systemFont(ofSize: 16, weight: .medium)
loadingLabel.textColor = .white
loadingLabel.alignment = .center
loadingLabel.frame = NSRect(x: 0, y: (mapHeight - 22) / 2, width: panelWidth, height: 22)
loadingView.addSubview(loadingLabel)

// Both modes share one panel, kept centered on the main screen
var mapView: KeymapView!  // built by openMap(), after the loader shows

func placePanel(width: CGFloat, height: CGFloat) {
    guard let screen = NSScreen.main else { return }
    let sf = screen.frame
    panel.setFrame(NSRect(x: sf.midX - width / 2, y: sf.midY - height / 2,
                          width: width, height: height), display: true)
}

// Show the map as it was, so the chip choice and the layer stay
func returnToMap() {
    panel.contentView = mapView
    placePanel(width: panelWidth, height: mapHeight)
    panel.makeFirstResponder(mapView)
}

func showMap(_ index: Int) {
    mapView.setLayer(index)
    returnToMap()
}

func showSearch() {
    panel.contentView = rootView
    placePanel(width: panelWidth, height: panelHeight)
    panel.makeFirstResponder(searchField)
}

// Builds the map and shows it in place of the loader
func openMap() {
    mapView = KeymapView(filePath: filePath, fkeyPath: fkeyPath)
    mapView.onSearch = { showSearch() }
    render("")
    showMap(0)  // the keyboard map opens first
    panel.makeFirstResponder(mapView)
}

panel.contentView = loadingView
placePanel(width: panelWidth, height: mapHeight)
app.activate(ignoringOtherApps: true)
panel.makeKeyAndOrderFront(nil)
DispatchQueue.main.async { openMap() }

// Retry focus shortly after launch in case activation raced
DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
    if !panel.didBecomeKey {
        app.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(mapView)
    }
}

app.run()
