import AppKit
import ApplicationServices

// Moves a Save / Open dialog to a folder by driving its own "Go to Folder" sheet (⌘⇧G),
// the same thing you'd do by hand, so it works in any app.

enum Keys {
    static let g: CGKeyCode = 5, a: CGKeyCode = 0, ret: CGKeyCode = 36, space: CGKeyCode = 49,
               delete: CGKeyCode = 51, escape: CGKeyCode = 53, up: CGKeyCode = 126

    static func post(_ key: CGKeyCode, flags: CGEventFlags = [], to pid: pid_t?) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        if let pid {
            down.postToPid(pid); usleep(4_000); up.postToPid(pid)
        } else {
            down.post(tap: .cghidEventTap); usleep(4_000); up.post(tap: .cghidEventTap)
        }
    }

    /// Types text as keyboard input. `pid` nil = through the system, like a real keyboard.
    static func type(_ text: String, to pid: pid_t?) {
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 16, units.count)])
            if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                if let pid { down.postToPid(pid); up.postToPid(pid) }
                else { down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap) }
            }
            i += 16
            usleep(6_000)
        }
    }
}

enum Navigator {
    private static let queue = DispatchQueue(label: "pathbar.navigate")

    private static func isTextInput(_ e: AXUIElement) -> Bool {
        let role = AX.string(e, kAXRoleAttribute) ?? ""
        if ["AXTextField", "AXComboBox", "AXTextArea", "AXSearchField"].contains(role) { return true }
        var settable: DarwinBoolean = false
        return role != "AXWindow" && role != "AXSheet"
            && AXUIElementIsAttributeSettable(e, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }

    /// First text field inside `root` (breadth-first, small budget).
    private static func findTextField(in root: AXUIElement) -> AXUIElement? {
        var queue = [root], budget = 300
        while !queue.isEmpty && budget > 0 {
            let e = queue.removeFirst()
            budget -= 1
            let role = AX.string(e, kAXRoleAttribute) ?? ""
            if role == "AXTextField" || role == "AXComboBox" { return e }
            queue += AX.children(e, limit: 40)
        }
        return nil
    }

    static func describe(_ e: AXUIElement?) -> String {
        guard let e else { return "none" }
        let d = AX.multi(e, [kAXRoleAttribute, kAXSubroleAttribute, "AXIdentifier", kAXDescriptionAttribute])
        return [kAXRoleAttribute, kAXSubroleAttribute, "AXIdentifier", kAXDescriptionAttribute]
            .compactMap { d[$0] as? String }.filter { !$0.isEmpty }.joined(separator: "/")
    }

    private static func sheets(_ e: AXUIElement) -> [AXUIElement] { PanelFinder.sheets(of: e) }

    /// Waits for the Go to Folder field to show up after the shortcut was sent.
    private static func waitForField(app: AXUIElement, panel: AXUIElement, before: AXUIElement?,
                                     sheetsBefore: [AXUIElement], windowsBefore: [AXUIElement],
                                     seconds: Double) -> (AXUIElement, String)? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            usleep(20_000)
            if let f = AX.element(app, kAXFocusedUIElementAttribute), !(before.map { CFEqual($0, f) } ?? false), isTextInput(f) {
                return (f, "focus")
            }
            for s in sheets(panel) where !sheetsBefore.contains(where: { CFEqual($0, s) }) {
                if let f = findTextField(in: s) { return (f, "new sheet") }
            }
            for w in AX.elements(app, kAXWindowsAttribute) where !windowsBefore.contains(where: { CFEqual($0, w) }) {
                if let f = findTextField(in: w) { return (f, "new window") }
            }
        }
        return nil
    }

    /// Presses one shortcut in the panel's app (brought to the front first). `done` runs on the main thread.
    static func press(_ key: CGKeyCode, flags: CGEventFlags, panel: FilePanel, done: @escaping () -> Void) {
        let app = panel.app, pid = panel.pid
        queue.async {
            _ = AX.set(app, kAXFrontmostAttribute, kCFBooleanTrue as CFTypeRef)
            for _ in 0..<15 where NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { usleep(20_000) }
            usleep(40_000)
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            Keys.post(key, flags: flags, to: front ? nil : pid)
            DispatchQueue.main.async { done() }
        }
    }

    /// The Go to Folder field, if that sheet is already open and focused.
    private static func openGoToField(_ app: AXUIElement) -> AXUIElement? {
        guard let f = AX.element(app, kAXFocusedUIElementAttribute) else { return nil }
        if AX.string(f, "AXIdentifier") == "PathTextField" { return f }
        if AX.string(f, "AXIdentifier") == "GoToWindow" { return findTextField(in: f) }
        return nil
    }

    /// Calls `done` on the main thread with (success, note for the log).
    /// Keys go through the system like real typing (apps ignore shortcuts sent straight to them),
    /// so the dialog's app has to be in front; it is brought there first if needed.
    static func go(to path: String, panel: FilePanel, done: @escaping (Bool, String) -> Void) {
        let app = panel.app, pid = panel.pid
        queue.async {
            var notes = [String]()
            func finish(_ ok: Bool) {
                let text = notes.joined(separator: "; ")
                DispatchQueue.main.async { done(ok, text) }
            }
            func front() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
            func key(_ k: CGKeyCode, _ flags: CGEventFlags = []) { Keys.post(k, flags: flags, to: front() ? nil : pid) }

            // Also hands the keyboard back to the dialog if the path bar had it.
            let wasFront = front()
            _ = AX.set(app, kAXFrontmostAttribute, kCFBooleanTrue as CFTypeRef)
            for _ in 0..<15 where !front() { usleep(20_000) }
            if !wasFront { notes.append(front() ? "brought app to front" : "app not in front") }
            usleep(60_000)

            var found: (AXUIElement, String)?
            if let f = openGoToField(app) { found = (f, "already open") }
            if found == nil {
                let before = AX.element(app, kAXFocusedUIElementAttribute)
                let sheetsBefore = sheets(panel.element)
                let windowsBefore = AX.elements(app, kAXWindowsAttribute)
                for attempt in 1...2 {
                    key(Keys.g, [.maskCommand, .maskShift])
                    found = waitForField(app: app, panel: panel.element, before: before,
                                         sheetsBefore: sheetsBefore, windowsBefore: windowsBefore, seconds: 0.8)
                    if found == nil, let f = openGoToField(app) { found = (f, "focused") }
                    if found != nil { break }
                    notes.append("⌘⇧G try \(attempt): nothing")
                }
            }
            guard let (field, how) = found else { return finish(false) }
            notes.append("Go to Folder: \(how) (\(describe(field)))")

            // Put the path in, then type a space and delete it: the sheet only reacts to typed changes.
            _ = AX.set(field, kAXFocusedAttribute, kCFBooleanTrue as CFTypeRef)
            _ = AX.set(field, kAXValueAttribute, path as CFString)
            usleep(30_000)
            if AX.string(field, kAXValueAttribute) == path {
                var end = CFRange(location: (path as NSString).length, length: 0)
                if let caret = AXValueCreate(.cfRange, &end) { _ = AX.set(field, kAXSelectedTextRangeAttribute, caret) }
                key(Keys.space); usleep(15_000); key(Keys.delete)
            } else {
                key(Keys.a, .maskCommand); usleep(30_000)
                Keys.type(path, to: front() ? nil : pid)
                notes.append("typed path")
            }
            usleep(120_000)
            if AX.string(field, kAXValueAttribute) != path {
                key(Keys.a, .maskCommand); usleep(30_000)
                Keys.type(path, to: front() ? nil : pid)
                usleep(150_000)
                notes.append("retyped path")
            }
            let value = AX.string(field, kAXValueAttribute) ?? ""
            if value != path { notes.append("field holds \"\(value)\"") }

            func closed() -> Bool { !AX.isAlive(field) || AX.frame(field) == nil }
            func waitClosed(_ seconds: Double) -> Bool {
                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline { usleep(20_000); if closed() { return true } }
                return false
            }
            key(Keys.ret)
            if waitClosed(0.8) { notes.append("confirmed"); return finish(true) }
            AXUIElementPerformAction(field, kAXConfirmAction as CFString)
            if waitClosed(0.5) { notes.append("confirmed via AXConfirm"); return finish(true) }
            notes.append("sheet stayed open, closing it")
            key(Keys.escape)
            finish(false)
        }
    }
}

// MARK: - Path text helpers

enum PathText {
    /// Turns whatever was typed or pasted into an absolute path.
    static func normalize(_ raw: String, relativeTo current: String?) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, let f = s.first, let l = s.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
            s = String(s.dropFirst().dropLast())
        }
        if s.hasPrefix("file://"), let u = URL(string: s) { s = u.path }
        if s.contains("\\ ") { s = s.replacingOccurrences(of: "\\ ", with: " ") }   // pasted from Terminal
        if s.isEmpty { return nil }
        s = (s as NSString).expandingTildeInPath
        if !s.hasPrefix("/") {
            guard let current else { return nil }
            s = (current as NSString).appendingPathComponent(s)
        }
        let std = (s as NSString).standardizingPath
        return std.isEmpty ? "/" : std
    }

    /// Tab completion for the last folder name, like a shell.
    static func complete(_ raw: String) -> String? {
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let dir: String, partial: String
        if expanded.hasSuffix("/") { dir = expanded; partial = "" }
        else { dir = (expanded as NSString).deletingLastPathComponent; partial = (expanded as NSString).lastPathComponent }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        let lower = partial.lowercased()
        let matches = names.filter { name in
            guard partial.hasPrefix(".") || !name.hasPrefix(".") else { return false }
            guard name.lowercased().hasPrefix(lower) else { return false }
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: (dir as NSString).appendingPathComponent(name), isDirectory: &isDir) && isDir.boolValue
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard let first = matches.first else { return nil }
        if matches.count == 1 { return (dir as NSString).appendingPathComponent(first) + "/" }
        var prefix = Array(first)
        for m in matches.dropFirst() {
            let a = Array(m.lowercased()), n = min(prefix.count, a.count)
            var i = 0
            while i < n && String(prefix[i]).lowercased() == String(a[i]) { i += 1 }
            prefix = Array(prefix[0..<i])
        }
        guard prefix.count > partial.count else { return nil }
        return (dir as NSString).appendingPathComponent(String(prefix))
    }
}
