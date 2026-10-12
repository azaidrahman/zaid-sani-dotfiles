// key-search-hud: fuzzy-searchable reference of all Karabiner layer bindings,
// with a keyboard map mode. Opened by hyper+shift+/.
//
// Usage: key-search-hud <keymap-index.tsv>
// The TSV comes from scripts/generate.py (columns: layer, trigger, key, label, action).
//
// Map mode (opens first): one view per layer. Left and right arrows switch layers.
//   Right arrow on the last layer, or the Search tab, opens search.
// Search mode: type to filter. Up and down scroll. Left arrow on an empty search opens the map.
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
    fputs("Usage: key-search-hud <keymap-index.tsv>\n", stderr)
    exit(1)
}

let filePath = (CommandLine.arguments[1] as NSString).expandingTildeInPath
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

enum ViewKind { case board, list, modifier }

struct LayerSpec {
    let id: String
    let title: String
    let kind: ViewKind
}

// Layer ids as they appear in the TSV, with the view each one uses
let layerSpecs = [
    LayerSpec(id: "app", title: "App", kind: .board),
    LayerSpec(id: "workspace", title: "Workspace", kind: .board),
    LayerSpec(id: "l1", title: "l1", kind: .list),
    LayerSpec(id: "l2", title: "l2", kind: .list),
    LayerSpec(id: "l3", title: "l3", kind: .list),
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

let mapHeight: CGFloat = 390
let margin: CGFloat = 24
let unit: CGFloat = 40      // distance between key origins
let keySize: CGFloat = 36
let boardTop: CGFloat = 112 // top of the first board row
let listTop: CGFloat = 84   // top of the list and the modifier chips

let boundColor = NSColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 1.0)
let modifiedColor = NSColor(red: 1.0, green: 0.75, blue: 0.35, alpha: 1.0)
let freeColor = NSColor(red: 0.45, green: 0.9, blue: 0.55, alpha: 1.0)
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
    var layers: [String: Layer] = [:]
    var lastModified: Date?
    var current = 0
    var hovered: String?
    var selectedMods = ""     // chip picked in the hyper view
    var keyRects: [(key: String, rect: NSRect)] = []
    var tabRects: [NSRect] = []
    var chipRects: [(mods: String, rect: NSRect)] = []
    var onSearch: (() -> Void)?  // called by right arrow on the last layer, and by the Search tab

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var spec: LayerSpec { layerSpecs[current] }
    var currentLayer: Layer { layers[spec.id] ?? Layer() }

    init(filePath: String) {
        self.filePath = filePath
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
        let spaceRect = NSRect(x: originX + 3 * unit, y: boardTop + 4 * unit,
                               width: 6 * unit - (unit - keySize), height: keySize)
        keyRects.append((key: spaceKey, rect: spaceRect))
    }

    func layoutTabs() {
        let gap: CGFloat = 6
        // One tab per layer, then the Search tab
        let count = CGFloat(layerSpecs.count + 1)
        let width = (panelWidth - margin * 2 - gap * (count - 1)) / count
        for i in 0..<Int(count) {
            let x = margin + CGFloat(i) * (width + gap)
            tabRects.append(NSRect(x: x, y: 16, width: width, height: 28))
        }
    }

    // Reload only when the file changed, so edits show up without reopening
    func reloadIfChanged() {
        let modified = (try? FileManager.default.attributesOfItem(atPath: filePath))?[.modificationDate] as? Date
        guard modified != lastModified else { return }
        lastModified = modified
        layers = loadLayers(filePath)
        needsDisplay = true
    }

    func setLayer(_ index: Int) {
        current = min(max(index, 0), layerSpecs.count - 1)
        hovered = nil
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

    // -- Events ----------------------------------------------------------------

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard spec.kind != .list else { return }
        let p = convert(event.locationInWindow, from: nil)
        let hit = keyRects.first(where: { $0.rect.contains(p) })?.key
        if hit != hovered {
            hovered = hit
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = tabRects.firstIndex(where: { $0.contains(p) }) {
            if i == layerSpecs.count { onSearch?() } else { setLayer(i) }
        } else if spec.kind == .modifier, let chip = chipRects.first(where: { $0.rect.contains(p) }) {
            selectedMods = chip.mods
            hovered = nil
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: NSApp.terminate(nil)                              // esc
        case 123: setLayer(current - 1)                            // left arrow
        case 124:                                                  // right arrow
            if current == layerSpecs.count - 1 { onSearch?() } else { setLayer(current + 1) }
        default: super.keyDown(with: event)
        }
    }

    // -- Drawing ---------------------------------------------------------------

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.1, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        drawTabs()
        drawInfo()
        switch spec.kind {
        case .board:
            drawBoard()
            drawBoardStatus()
        case .list:
            drawList()
            drawListStatus()
        case .modifier:
            drawChips()
            drawBoard()
            drawBoardStatus()
        }
    }

    func drawTabs() {
        for (i, r) in tabRects.enumerated() {
            let on = i == current
            let title = i < layerSpecs.count ? layerSpecs[i].title : "Search"
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
        case .modifier:
            let name = selectedMods.isEmpty ? "no modifier" : selectedMods
            text = "held \(layer.trigger)   ·   \(name)   ·   \(boundCount()) bound   ·   \(freeCount()) free"
        }
        drawText(text, in: NSRect(x: margin, y: 54, width: panelWidth - margin * 2, height: 18),
                 size: 12, color: .white)
    }

    func boundCount() -> Int {
        gridKeys.filter { !boardBindings($0).isEmpty }.count
    }

    func freeCount() -> Int {
        gridKeys.count - boundCount()
    }

    // Chips that pick the modifier set shown on the hyper board
    func drawChips() {
        chipRects = []
        var x = margin
        for mods in modifierSets() {
            let width: CGFloat = 70
            let rect = NSRect(x: x, y: listTop, width: width, height: 22)
            chipRects.append((mods: mods, rect: rect))
            let on = mods == selectedMods
            (on ? NSColor(white: 1, alpha: 0.2) : NSColor(white: 1, alpha: 0.06)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            drawText(mods.isEmpty ? "plain" : mods, in: NSRect(x: rect.minX, y: rect.minY + 4, width: width, height: 16),
                     size: 12, weight: on ? .semibold : .regular, color: on ? .white : dimColor, align: .center)
            x += width + 6
        }
    }

    func drawBoard() {
        for (key, rect) in keyRects {
            let bs = boardBindings(key)
            let isHover = key == hovered
            let name = key == spaceKey ? "space" : key
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)

            if bs.isEmpty {
                path.lineWidth = isHover ? 2 : 1
                freeColor.withAlphaComponent(isHover ? 0.95 : 0.45).setStroke()
                path.stroke()
                drawText(name, in: NSRect(x: rect.minX, y: rect.minY + 9, width: rect.width, height: 18),
                         size: 13, weight: .medium, color: dimColor, align: .center)
            } else {
                let hasBare = bs.contains(where: { $0.mods.isEmpty })
                (hasBare ? boundColor : modifiedColor).withAlphaComponent(isHover ? 1 : 0.85).setFill()
                path.fill()
                let shown = bs.first(where: { $0.mods.isEmpty }) ?? bs[0]
                drawText(name, in: NSRect(x: rect.minX, y: rect.minY + 2, width: rect.width, height: 16),
                         size: 12, weight: .semibold, color: ink, align: .center)
                drawText(String(shown.label.prefix(7)),
                         in: NSRect(x: rect.minX, y: rect.minY + 19, width: rect.width, height: 14),
                         size: 8, color: ink, align: .center)
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

        if let key = hovered {
            let name = key == spaceKey ? "space" : key
            let bs = boardBindings(key)
            if !bs.isEmpty {
                title = bs.map { "\($0.mods)\(name)  \($0.label)" }.joined(separator: "   ·   ")
                detail = bs.map { "\($0.mods)\(name) → \($0.action)" }.joined(separator: "   |   ")
            } else {
                title = "\(name) is free in \(spec.title)."
                detail = ""
            }
        }
        drawStatusLines(title: title, detail: detail,
                        hint: "blue bound · amber modifier only · green free · ← → layers · → on Hyper opens search")
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
        drawText(detail, in: NSRect(x: margin, y: 344, width: width, height: 16),
                 size: 11, color: dimColor)
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
searchField.placeholderString = "search keys…  (← keyboard map)"
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
        render(searchField.stringValue)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)),
             #selector(NSResponder.insertNewline(_:)):
            NSApp.terminate(nil)
            return true
        case #selector(NSResponder.moveLeft(_:)):
            // Only on an empty search, so the arrow still moves the cursor while typing
            guard searchField.stringValue.isEmpty else { return false }
            showMap(layerSpecs.count - 1)
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

// Both modes share one panel, kept centered on the main screen
let mapView = KeymapView(filePath: filePath)
mapView.onSearch = { showSearch() }

func placePanel(width: CGFloat, height: CGFloat) {
    guard let screen = NSScreen.main else { return }
    let sf = screen.frame
    panel.setFrame(NSRect(x: sf.midX - width / 2, y: sf.midY - height / 2,
                          width: width, height: height), display: true)
}

func showMap(_ index: Int) {
    mapView.setLayer(index)
    panel.contentView = mapView
    placePanel(width: panelWidth, height: mapHeight)
    panel.makeFirstResponder(mapView)
}

func showSearch() {
    panel.contentView = rootView
    placePanel(width: panelWidth, height: panelHeight)
    panel.makeFirstResponder(searchField)
}

render("")
showMap(0)  // the keyboard map opens first
app.activate(ignoringOtherApps: true)
panel.makeKeyAndOrderFront(nil)
panel.makeFirstResponder(mapView)

// Retry focus shortly after launch in case activation raced
DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
    if !panel.didBecomeKey {
        app.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(mapView)
    }
}

app.run()
