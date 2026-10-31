import AppKit
import ApplicationServices

// Small helpers around the Accessibility API, used to read other apps' windows.

enum AX {
    static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
        return v
    }

    static func string(_ e: AXUIElement, _ name: String) -> String? { attr(e, name) as? String }

    static func element(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attr(e, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ e: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let v = attr(e, name), CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
        return (v as? [AXUIElement]) ?? []
    }

    static func count(_ e: AXUIElement, _ name: String) -> Int {
        var n: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(e, name as CFString, &n) == .success else { return -1 }
        return n
    }

    /// Children, but at most `limit` of them (file lists can hold thousands of rows).
    static func children(_ e: AXUIElement, limit: Int = 400) -> [AXUIElement] {
        let n = count(e, kAXChildrenAttribute)
        if n == 0 { return [] }
        if n < 0 || n <= limit { return elements(e, kAXChildrenAttribute) }
        var out: CFArray?
        guard AXUIElementCopyAttributeValues(e, kAXChildrenAttribute as CFString, 0, limit, &out) == .success,
              let arr = out as? [AXUIElement] else { return [] }
        return arr
    }

    /// Several attributes in one round trip. Missing ones are left out.
    static func multi(_ e: AXUIElement, _ names: [String]) -> [String: CFTypeRef] {
        var out: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(e, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &out) == .success,
              let arr = out as? [CFTypeRef] else { return [:] }
        var d = [String: CFTypeRef]()
        for (i, v) in arr.enumerated() where i < names.count {
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { continue }
            d[names[i]] = v
        }
        return d
    }

    /// Frame in Accessibility coordinates (origin at the top-left of the main display).
    static func frame(_ e: AXUIElement) -> CGRect? {
        let d = multi(e, [kAXPositionAttribute, kAXSizeAttribute])
        guard let p = d[kAXPositionAttribute], let s = d[kAXSizeAttribute],
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    static func url(_ v: CFTypeRef?) -> URL? {
        guard let v else { return nil }
        if CFGetTypeID(v) == CFURLGetTypeID() { return (v as! CFURL) as URL }
        if let s = v as? String {
            if s.hasPrefix("file://") { return URL(string: s) }
            if s.hasPrefix("/") { return URL(fileURLWithPath: s) }
        }
        return nil
    }

    /// False only when the element is really gone. A slow or busy app (e.g. while its
    /// Go to Folder sheet is open) answers with a timeout, which still counts as alive.
    static func isAlive(_ e: AXUIElement) -> Bool {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &v)
        return err != .invalidUIElement
    }

    static func set(_ e: AXUIElement, _ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(e, name as CFString, value) == .success
    }

    static func describe(_ v: CFTypeRef?) -> String {
        guard let v else { return "nil" }
        if let s = v as? String { return s.count > 90 ? String(s.prefix(90)) + "…" : s }
        if let n = v as? NSNumber { return n.stringValue }
        if let u = url(v) { return u.absoluteString }
        if CFGetTypeID(v) == AXUIElementGetTypeID() { return "<element>" }
        if CFGetTypeID(v) == CFArrayGetTypeID() { return "<array \((v as? [AnyObject])?.count ?? 0)>" }
        if CFGetTypeID(v) == AXValueGetTypeID() {
            let av = v as! AXValue
            switch AXValueGetType(av) {
            case .cgPoint: var p = CGPoint.zero; AXValueGetValue(av, .cgPoint, &p); return "(\(Int(p.x)),\(Int(p.y)))"
            case .cgSize: var s = CGSize.zero; AXValueGetValue(av, .cgSize, &s); return "[\(Int(s.width))x\(Int(s.height))]"
            default: return "<axvalue>"
            }
        }
        return String(describing: v)
    }
}

// MARK: - Finding Save / Open dialogs

final class FilePanel {
    let pid: pid_t
    let app: AXUIElement
    let element: AXUIElement      // the dialog window or sheet
    let kind: String              // "save", "open", "panel" (not sure which) or "finder" (a Finder window)
    var popup: AXUIElement?       // the folder pop-up ("SRT ⌃⌄" in the toolbar, or "Where:")
    var popupValue: String?       // its value; for Finder windows, the window title
    var path: String?             // current folder, nil when unknown
    var dumped = false
    var unknownScans = 0
    /// Finder only: where the bar sits in the toolbar, relative to the window's top-left. nil = dock above.
    var slot: CGRect?
    var wideSlot: CGRect?         // while typing: stretches to the search field
    var titleRect: CGRect?        // Finder: the window title; clicking it shows the bar
    var slotWidth: CGFloat = 0    // window width the slot was measured for
    /// Finder: the bar is hidden until you click the window title.
    var revealed = false
    /// Window-server id of the window (nil if it couldn't be matched; then Accessibility is used).
    var windowID: CGWindowID?
    var frame: CGRect?            // last known frame, Accessibility (top-left) coordinates
    var popupWatched = false

    var isFinder: Bool { kind == "finder" }

    init(pid: pid_t, app: AXUIElement, element: AXUIElement, kind: String) {
        self.pid = pid; self.app = app; self.element = element; self.kind = kind
    }
}

enum PanelFinder {
    static let saveButtons: Set<String> = ["Save", "Export", "Save As", "Download", "Move", "Copy", "Create"]
    static let openButtons: Set<String> = ["Open", "Choose", "Select", "Import", "Upload", "Add", "Insert", "Attach"]

    /// The Save / Open dialog of app `pid`, if one is showing.
    static func find(pid: pid_t) -> FilePanel? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        var seen = [AXUIElement]()
        func consider(_ e: AXUIElement) -> FilePanel? {
            if seen.contains(where: { CFEqual($0, e) }) { return nil }
            seen.append(e)
            if let kind = classify(e) { return FilePanel(pid: pid, app: app, element: e, kind: kind) }
            return nil
        }
        let focusedWindow = AX.element(app, kAXFocusedWindowAttribute)
        if let fw = focusedWindow, let p = consider(fw) { return p }
        for w in AX.elements(app, kAXWindowsAttribute).prefix(10) {
            let d = AX.multi(w, [kAXRoleAttribute, kAXCancelButtonAttribute])
            if d[kAXCancelButtonAttribute] != nil, let p = consider(w) { return p }
        }
        // Sheets of the focused window, when it is small enough to look through cheaply.
        if let fw = focusedWindow, AX.count(fw, kAXChildrenAttribute) <= 60 {
            for s in sheets(of: fw) { if let p = consider(s) { return p } }
        }
        // A dialog sheet holds the keyboard focus: ask the focused control which window it is in.
        if let f = AX.element(app, kAXFocusedUIElementAttribute) {
            for a in [kAXWindowAttribute, kAXTopLevelUIElementAttribute] {
                if let w = AX.element(f, a), let p = consider(w) { return p }
            }
        }
        return nil
    }

    /// The front Finder browser window (one with a toolbar), if Finder's focus is on one.
    static func findFinderWindow(pid: pid_t) -> FilePanel? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        guard let w = AX.element(app, kAXFocusedWindowAttribute) else { return nil }
        let d = AX.multi(w, [kAXRoleAttribute, kAXSubroleAttribute])
        guard d[kAXRoleAttribute] as? String == "AXWindow",
              d[kAXSubroleAttribute] as? String == "AXStandardWindow",
              toolbar(of: w) != nil else { return nil }
        return FilePanel(pid: pid, app: app, element: w, kind: "finder")
    }

    static func toolbar(of w: AXUIElement) -> AXUIElement? {
        AX.children(w, limit: 40).first { AX.string($0, kAXRoleAttribute) == "AXToolbar" }
    }

    /// The free stretch of a Finder toolbar between the ←/→ buttons and the next control
    /// (where the window title is), and a wider one reaching to the search field for typing.
    /// Relative to the window's top-left; nil if too narrow.
    static func toolbarSlot(window: AXUIElement, frame wf: CGRect) -> (normal: CGRect, wide: CGRect, title: CGRect)? {
        guard let tb = toolbar(of: window), let tf = AX.frame(tb) else { return nil }
        var items: [(role: String, text: String, frame: CGRect)] = []
        func add(_ e: AXUIElement, depth: Int) {
            let d = AX.multi(e, [kAXRoleAttribute, kAXDescriptionAttribute, kAXTitleAttribute, "AXIdentifier"])
            let role = d[kAXRoleAttribute] as? String ?? ""
            let text = [kAXDescriptionAttribute, kAXTitleAttribute, "AXIdentifier"]
                .compactMap { d[$0] as? String }.joined(separator: " ").lowercased()
            if let f = AX.frame(e), f.width > 6, f.height > 6 { items.append((role, text, f)) }
            if depth < 2 && (role == "AXGroup" || role == "AXSegmentedControl") {
                for c in AX.children(e, limit: 12) { add(c, depth: depth + 1) }
            }
        }
        for c in AX.children(tb, limit: 40) { add(c, depth: 0) }
        let nav = items.filter { $0.text.contains("back") || $0.text.contains("forward") }
        let left = max(nav.map { $0.frame.maxX }.max() ?? wf.minX + 150, wf.minX + 140)
        let controls = items.filter {
            $0.role != "AXStaticText" && $0.role != "AXGroup" && $0.frame.minX > left + 30 && $0.frame.maxX <= wf.maxX
        }
        let right = min(controls.map { $0.frame.minX }.min() ?? tf.maxX - 12, wf.maxX - 12)
        let h: CGFloat = 30
        let midY = nav.first.map { $0.frame.midY } ?? tf.midY
        let slot = CGRect(x: left + 10, y: midY - h / 2, width: right - left - 20, height: h)
        guard slot.width >= 220 else { return nil }
        let search = controls.filter { $0.role == "AXTextField" }.map { $0.frame.minX }.min()
        let wideRight = min(search ?? tf.maxX - 12, wf.maxX - 12)
        var wide = slot
        wide.size.width = max(slot.width, wideRight - 10 - slot.minX)
        // The title text Finder draws in that gap (what you click to show the bar).
        let title = AX.children(window, limit: 40).lazy
            .filter { AX.string($0, kAXRoleAttribute) == "AXStaticText" }
            .compactMap { AX.frame($0) }
            .first { $0.midY >= tf.minY && $0.midY <= tf.maxY && $0.width > 20 } ?? slot
        let rel = { (r: CGRect) in r.offsetBy(dx: -wf.minX, dy: -wf.minY) }
        return (rel(slot), rel(wide), rel(title))
    }

    static func sheets(of w: AXUIElement) -> [AXUIElement] {
        AX.children(w, limit: 80).filter { AX.string($0, kAXRoleAttribute) == "AXSheet" }
    }

    /// "save" / "open" / "panel" if `e` looks like a file dialog, else nil.
    static func classify(_ e: AXUIElement) -> String? {
        let d = AX.multi(e, [kAXRoleAttribute, "AXIdentifier", kAXCancelButtonAttribute, kAXDefaultButtonAttribute])
        let id = (d["AXIdentifier"] as? String ?? "").lowercased()
        if id.contains("save-panel") || id.contains("savepanel") { return "save" }
        if id.contains("open-panel") || id.contains("openpanel") { return "open" }
        // Every file dialog has a Cancel button; most windows don't, so this keeps the check cheap.
        guard let cancel = d[kAXCancelButtonAttribute], CFGetTypeID(cancel) == AXUIElementGetTypeID() else { return nil }
        var roles = Set<String>()
        var budget = 220
        scanRoles(e, depth: 0, budget: &budget, into: &roles)
        let hasPopup = roles.contains("AXPopUpButton")
        let hasBrowser = roles.contains("AXSplitGroup") || roles.contains("AXBrowser") || roles.contains("AXOutline")
        var title = ""
        if let def = d[kAXDefaultButtonAttribute], CFGetTypeID(def) == AXUIElementGetTypeID() {
            title = AX.string(def as! AXUIElement, kAXTitleAttribute) ?? ""
        }
        if hasPopup && hasBrowser {
            if saveButtons.contains(title) { return "save" }
            if openButtons.contains(title) { return "open" }
            return "panel"
        }
        // The small (collapsed) Save dialog: name field + "Where:" pop-up, no file list.
        if hasPopup && roles.contains("AXTextField") && saveButtons.contains(title) { return "save" }
        return nil
    }

    private static func scanRoles(_ e: AXUIElement, depth: Int, budget: inout Int, into roles: inout Set<String>) {
        guard depth < 7, budget > 0 else { return }
        for c in AX.children(e, limit: 30) {
            guard budget > 0 else { return }
            budget -= 1
            if let r = AX.string(c, kAXRoleAttribute) { roles.insert(r) }
            scanRoles(c, depth: depth + 1, budget: &budget, into: &roles)
        }
    }
}

// MARK: - Reading the dialog's current folder

struct LocationScan {
    var popups: [(element: AXUIElement, value: String, frame: CGRect?, nearSearch: Bool)] = []
    var urls: [URL] = []
    var document: URL?
}

enum Location {
    /// Folder shown in a Finder window: its document URL, else worked out from its rows.
    static func finderFolder(_ window: AXUIElement, previous: String?, recents: [String]) -> (path: String?, title: String?, urls: Int) {
        let title = AX.string(window, kAXTitleAttribute)
        if let doc = AX.url(AX.attr(window, "AXDocument")), doc.isFileURL {
            var isDir: ObjCBool = false
            let p = doc.standardizedFileURL.path
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { return (p, title, 0) }
        }
        let s = scan(window)
        return (resolve(name: title, urls: s.urls, document: s.document, previous: previous, recents: recents), title, s.urls.count)
    }

    static let nodeAttrs = [kAXRoleAttribute, kAXSubroleAttribute, "AXIdentifier", "AXURL", "AXDocument", kAXDescriptionAttribute]

    static func scan(_ panel: AXUIElement) -> LocationScan {
        var s = LocationScan()
        if let doc = AX.url(AX.attr(panel, "AXDocument")) { s.document = doc }
        var budget = 900
        walk(panel, depth: 0, budget: &budget, into: &s)
        return s
    }

    private static func walk(_ e: AXUIElement, depth: Int, budget: inout Int, into s: inout LocationScan) {
        guard depth < 28, budget > 0 else { return }
        budget -= 1
        let d = AX.multi(e, nodeAttrs)
        let role = d[kAXRoleAttribute] as? String ?? ""
        let ident = (d["AXIdentifier"] as? String ?? "").lowercased()
        let desc = (d[kAXDescriptionAttribute] as? String ?? "").lowercased()
        // The sidebar lists favourites from all over the disk; they say nothing about the current folder.
        if ident.contains("sidebar") || desc == "sidebar" { return }
        if let u = AX.url(d["AXURL"]), u.isFileURL { s.urls.append(u) }
        if let u = AX.url(d["AXDocument"]), u.isFileURL, s.document == nil { s.document = u }
        if role == "AXPopUpButton" {
            if let v = AX.string(e, kAXValueAttribute), !v.isEmpty {
                s.popups.append((e, v, AX.frame(e), false))
            }
            return
        }
        // Long lists: the first rows and the selected ones are enough to know the folder.
        let n = AX.count(e, kAXChildrenAttribute)
        var kids: [AXUIElement]
        if n > 40 {
            kids = AX.children(e, limit: 6)
            kids += AX.elements(e, kAXSelectedRowsAttribute).prefix(4)
            kids += AX.elements(e, kAXSelectedChildrenAttribute).prefix(4)
        } else {
            kids = AX.children(e, limit: 40)
        }
        let isToolbarLike = kids.contains { AX.string($0, kAXSubroleAttribute) == "AXSearchField" }
        let before = s.popups.count
        for c in kids { walk(c, depth: depth + 1, budget: &budget, into: &s) }
        if isToolbarLike {
            for i in before..<s.popups.count { s.popups[i].nearSearch = true }
        }
    }

    /// The pop-up that names the current folder: the one beside the search field, else the topmost.
    static func folderPopup(_ s: LocationScan) -> (element: AXUIElement, value: String)? {
        if let p = s.popups.first(where: { $0.nearSearch }) { return (p.element, p.value) }
        let sorted = s.popups.sorted { ($0.frame?.minY ?? .greatestFiniteMagnitude) < ($1.frame?.minY ?? .greatestFiniteMagnitude) }
        return sorted.first.map { ($0.element, $0.value) }
    }

    /// Works out the folder path from what the dialog shows.
    static func resolve(name: String?, urls: [URL], document: URL?, previous: String?, recents: [String]) -> String? {
        let fm = FileManager.default
        func isDir(_ p: String) -> Bool { var b: ObjCBool = false; return fm.fileExists(atPath: p, isDirectory: &b) && b.boolValue }
        func matches(_ p: String) -> Bool {
            guard let name else { return true }
            return fm.displayName(atPath: p) == name || (p as NSString).lastPathComponent == name
                || (p == "/" && name == fm.displayName(atPath: "/"))
        }
        if let doc = document?.path, isDir(doc), matches(doc) { return doc }

        // The folder the listed items live in comes first; a listed sub-folder with the same
        // name (e.g. Projects/Projects) only counts when the current folder is empty.
        var parents = [String](), listedFolders = [String]()
        for u in urls {
            let p = u.standardizedFileURL.path
            let parent = (p as NSString).deletingLastPathComponent
            if !parent.isEmpty { parents.append(parent) }
            if isDir(p) { listedFolders.append(p) }
        }
        let candidates = parents + listedFolders
        for group in [parents, listedFolders] {
            let good = group.filter { isDir($0) && matches($0) }
            if let best = good.max(by: { $0.count < $1.count }) { return best }
        }
        if name == nil, !candidates.isEmpty {
            // No name to check against: the folder most rows live in.
            let parents = urls.map { ($0.standardizedFileURL.path as NSString).deletingLastPathComponent }
            let counts = Dictionary(parents.map { ($0, 1) }, uniquingKeysWith: +)
            return counts.max { $0.value < $1.value }?.key
        }
        guard let name else { return nil }
        // Empty folder or small dialog: guess from where we just were.
        if let prev = previous {
            let child = (prev as NSString).appendingPathComponent(name)
            if isDir(child) { return child }
            var p = prev
            while p != "/" && !p.isEmpty {
                if matches(p) { return p }
                p = (p as NSString).deletingLastPathComponent
            }
            if matches("/") { return "/" }
        }
        let home = NSHomeDirectory()
        let known = recents + [home, home + "/Desktop", home + "/Documents", home + "/Downloads",
                               home + "/Movies", home + "/Music", home + "/Pictures", "/Applications"]
        return known.first { isDir($0) && matches($0) }
    }
}

// MARK: - Diagnostic dump (written when the folder can't be worked out, or on request)

enum Dumper {
    static let attrs = [kAXRoleAttribute, kAXSubroleAttribute, "AXIdentifier", kAXTitleAttribute, kAXValueAttribute,
                        kAXDescriptionAttribute, "AXURL", "AXDocument", "AXFilename", kAXPositionAttribute,
                        kAXSizeAttribute, kAXSelectedAttribute, kAXFocusedAttribute]

    static func dump(_ root: AXUIElement, app: AXUIElement?, title: String) -> String {
        var out = "=== \(title) — \(Date())\n"
        if let app {
            if let f = AX.element(app, kAXFocusedUIElementAttribute) {
                out += "focused element: " + line(f) + "\n"
                var e: AXUIElement? = AX.element(f, kAXParentAttribute)
                var n = 0
                while let cur = e, n < 12 {
                    out += "   ↳ parent: " + line(cur) + "\n"
                    e = AX.element(cur, kAXParentAttribute)
                    n += 1
                }
            }
            if let w = AX.element(app, kAXFocusedWindowAttribute) { out += "focused window: " + line(w) + "\n" }
            for w in AX.elements(app, kAXWindowsAttribute) {
                out += "app window: " + line(w) + "\n"
                for s in PanelFinder.sheets(of: w) { out += "   sheet: " + line(s) + "\n" }
            }
        }
        var namesShown = Set<String>()
        var budget = 3000
        walk(root, depth: 0, budget: &budget, namesShown: &namesShown, out: &out)
        return out
    }

    private static func line(_ e: AXUIElement) -> String {
        let d = AX.multi(e, attrs)
        var parts = [String]()
        for a in attrs { if let v = d[a] { parts.append("\(a.replacingOccurrences(of: "AX", with: ""))=\(AX.describe(v))") } }
        return parts.joined(separator: " | ")
    }

    private static func walk(_ e: AXUIElement, depth: Int, budget: inout Int, namesShown: inout Set<String>, out: inout String) {
        guard budget > 0, depth < 40 else { return }
        budget -= 1
        let pad = String(repeating: "  ", count: depth)
        let n = AX.count(e, kAXChildrenAttribute)
        out += pad + line(e) + (n > 0 ? " | children=\(n)" : "") + "\n"
        let role = AX.string(e, kAXRoleAttribute) ?? "?"
        if !namesShown.contains(role) {
            namesShown.insert(role)
            var names: CFArray?
            if AXUIElementCopyAttributeNames(e, &names) == .success, let list = names as? [String] {
                out += pad + "  · attributes: " + list.joined(separator: ", ") + "\n"
            }
            var acts: CFArray?
            if AXUIElementCopyActionNames(e, &acts) == .success, let list = acts as? [String], !list.isEmpty {
                out += pad + "  · actions: " + list.joined(separator: ", ") + "\n"
            }
        }
        let kids = AX.children(e, limit: depth < 8 ? 30 : 8)
        for c in kids { walk(c, depth: depth + 1, budget: &budget, namesShown: &namesShown, out: &out) }
        if n > kids.count { out += pad + "  … \(n - kids.count) more children\n" }
    }
}
