import AppKit
import ApplicationServices

// PathBar: a Windows-style address bar for macOS Save and Open dialogs (browser downloads,
// "Save As…", "Open…", uploads). It floats on top of the dialog, shows the full path of the
// folder the dialog is in, and you can type or paste a path and press Return to jump there.

setvbuf(stdout, nil, _IOLBF, 0)

let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/PathBar.log")
let dumpURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/PathBar-dump.txt")

func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
    let line = "\(stamp) \(message)\n"
    print(line, terminator: "")
    guard isatty(STDOUT_FILENO) == 0, ProcessInfo.processInfo.environment["PATHBAR_LAUNCHD"] == nil else { return }
    // Started with `open` (no launchd log redirect): append to the log file ourselves.
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.data(using: .utf8)!.write(to: logURL)
    }
}

final class Controller: NSObject, BarDelegate, NSMenuDelegate {
    private let bar = Bar()
    private var panel: FilePanel?
    private var finding = false
    private var scanning = false
    private var navigating = false
    private var checkPending = false
    private var lastScan = Date.distantPast
    private var lastPoll = Date.distantPast
    private var lastMatch = Date.distantPast
    private var lastAXFrame = Date.distantPast
    private var statusItem: NSStatusItem!
    private let scanQueue = DispatchQueue(label: "pathbar.scan")
    private let defaults = UserDefaults.standard
    private var trusted = false
    /// Test hook: treat this process as the front app (set with the "pid:<n>" command).
    private var forcedPid: pid_t?
    /// New windows / focus changes in the front app, so dialogs are picked up at once.
    private var appWatcher: AXWatcher?
    private var appWatcherPid: pid_t = 0
    /// The tracked window: closed, renamed (Finder), folder pop-up changed (dialogs).
    private var panelWatcher: AXWatcher?
    /// Runs once per screen refresh, only while the bar is on screen.
    private lazy var clock = FrameClock { [weak self] in self?.frameTick() }
    private var mouseDown: (point: CGPoint, time: Date)?
    /// After a click on a dialog's Save/Cancel the dialog is closing: keep the bar hidden meanwhile.
    private var hiddenUntil = Date.distantPast

    private func frontPid() -> pid_t? {
        forcedPid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }
    /// Also offer the bar in Finder windows (menu toggle).
    private var finderEnabled: Bool {
        get { defaults.object(forKey: "finder") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "finder") }
    }
    private var lastSlotMeasure = Date.distantPast
    private var recents: [String] {
        get { defaults.stringArray(forKey: "recents") ?? [] }
        set { defaults.set(Array(newValue.prefix(15)), forKey: "recents") }
    }

    func start() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        bar.delegate = self
        setupStatusItem()
        trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        log("started (pid \(getpid())), accessibility \(trusted ? "granted" : "NOT granted yet")")

        // Safety net; most changes arrive as notifications (below).
        let slow = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(slow, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // Clicks in other apps: Finder title clicks show the bar, clicks elsewhere hide it.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] e in self?.globalMouse(e) }
        watchFrontApp()

        // Test hooks, off unless turned on with: defaults write local.pathbar.helper debug -bool true
        // (any program can send these, so they stay off in normal use).
        if defaults.bool(forKey: "debug") {
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(debugCommand(_:)), name: Notification.Name("local.pathbar.cmd"),
                object: nil, suspensionBehavior: .deliverImmediately)
            log("debug commands on")
        }
    }

    // MARK: Watching for dialogs and Finder windows

    @objc private func appActivated(_ note: Notification) {
        // Hide right away when you switch apps; don't wait for the next check.
        if let p = panel {
            if frontPid() != p.pid {
                if p.isFinder { conceal() } else { bar.hide(); clock.stop() }
            } else if !p.isFinder {
                clock.start()
            }
        }
        watchFrontApp()
        scheduleCheck()
    }

    private func watchFrontApp() {
        guard trusted, let pid = frontPid(), pid != getpid() else { return }
        if pid == appWatcherPid, appWatcher != nil { return }
        appWatcherPid = pid
        appWatcher = AXWatcher(pid: pid)
        appWatcher?.handler = { [weak self] _, _ in self?.scheduleCheck() }
        appWatcher?.watch(AXUIElementCreateApplication(pid),
                          [kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification, "AXSheetCreated"])
    }

    /// Runs `check()` once soon, however many notifications arrive together.
    private func scheduleCheck() {
        guard !checkPending else { return }
        checkPending = true
        DispatchQueue.main.async { self.checkPending = false; self.check() }
    }

    private func check() {
        let nowTrusted = AXIsProcessTrusted()
        if nowTrusted != trusted {
            trusted = nowTrusted
            log("accessibility \(trusted ? "granted" : "revoked")")
            updateStatusIcon()
            if trusted { watchFrontApp() }
        }
        guard enabled, trusted, let pid = frontPid() else { dropPanel(); return }
        if pid == getpid() { return }
        if let p = panel {
            var keep = p.pid == pid && (navigating || AX.isAlive(p.element))
            // Finder: follow its focus to another window (or to a dialog it shows).
            // (Not while you type in the bar: Finder then reports another window as focused.)
            if keep, p.isFinder, !navigating, !bar.panel.isKeyWindow,
               let fw = AX.element(p.app, kAXFocusedWindowAttribute), !CFEqual(fw, p.element) {
                keep = false
            }
            if keep {
                // Back in the dialog's app (or Finder bar open): make sure the bar follows again.
                if (!p.isFinder || p.revealed) && !clock.running { clock.start() }
                // Occasional full re-read as a safety net (Finder: only while its bar is open).
                if !scanning && !navigating && (!p.isFinder || p.revealed) && Date().timeIntervalSince(lastScan) > 2 {
                    scanLocation()
                }
                return
            }
            dropPanel()
        }
        guard !finding else { return }
        finding = true
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        let wantFinder = finderEnabled && NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.finder"
        scanQueue.async {
            let found = PanelFinder.find(pid: pid) ?? (wantFinder ? PanelFinder.findFinderWindow(pid: pid) : nil)
            DispatchQueue.main.async {
                self.finding = false
                guard let found, self.panel == nil, self.frontPid() == found.pid else { return }
                self.adopt(found, appName: appName)
            }
        }
    }

    private func adopt(_ p: FilePanel, appName: String) {
        AXUIElementSetMessagingTimeout(p.element, 0.25)
        panel = p
        if let f = AX.frame(p.element) {
            p.frame = f
            p.windowID = WindowServer.windowID(pid: p.pid, frame: f)
        }
        if p.windowID == nil {
            // Still animating open: try again once it has settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.matchWindow(p) }
        }
        let ident = AX.string(p.element, "AXIdentifier") ?? "-"
        log("\(p.isFinder ? "Finder window" : "dialog") found: \(appName) (pid \(p.pid)) kind=\(p.kind) id=\(ident) window=\(p.windowID.map(String.init) ?? "unmatched")")
        bar.finderMode = p.isFinder
        bar.setPath(nil, name: nil, force: true)
        let watcher = AXWatcher(pid: p.pid)
        watcher?.handler = { [weak self] name, element in self?.panelEvent(name, element) }
        watcher?.watch(p.element, [kAXUIElementDestroyedNotification, kAXTitleChangedNotification])
        panelWatcher = watcher
        if !p.isFinder {
            frameTick()
            clock.start()   // the dialog bar is always shown: follow the dialog every frame
        }
        scanLocation()
        if defaults.bool(forKey: "autodump") { writeDump(p, reason: "autodump") }
    }

    /// Finds the window-server id for the tracked window (so it can be followed without asking the app).
    private func matchWindow(_ p: FilePanel) {
        guard panel === p, p.windowID == nil, let f = AX.frame(p.element) else { return }
        p.frame = f
        p.windowID = WindowServer.windowID(pid: p.pid, frame: f)
        if let id = p.windowID { log("window matched: \(id)") }
    }

    private func panelEvent(_ name: String, _ element: AXUIElement) {
        guard let p = panel else { return }
        switch name {
        case kAXUIElementDestroyedNotification:
            guard CFEqual(element, p.element) else { return }
            if bar.visible { log("window closed: bar hidden") }
            bar.hide()          // closed: hide this instant
            dropPanel()
            scheduleCheck()
        case kAXTitleChangedNotification, kAXValueChangedNotification:
            if !navigating { scanLocation() }
        default:
            break
        }
    }

    /// Keeps the bar glued to its window. Runs every screen refresh, only while the bar is shown.
    private func frameTick() {
        guard let p = panel else { clock.stop(); return }
        if p.isFinder && !p.revealed { bar.hide(); clock.stop(); return }
        guard frontPid() == p.pid, Date() >= hiddenUntil else { bar.hide(); return }
        if p.windowID == nil, Date().timeIntervalSince(lastMatch) > 0.3 {
            lastMatch = Date()
            matchWindow(p)
        }
        var frame: CGRect?
        if let id = p.windowID {
            frame = WindowServer.frame(of: id)
        } else if Date().timeIntervalSince(lastAXFrame) > 0.05 {
            lastAXFrame = Date()
            frame = AX.frame(p.element)       // fallback: ask the app (slower)
        } else {
            frame = p.frame
        }
        guard let f = frame, f.width > 150, f.height > 80 else {
            // Closed, minimised or moved to another Space: hide now, check() tidies up.
            if bar.visible { log("window left the screen: bar hidden") }
            if p.isFinder { conceal() } else { bar.hide() }
            return
        }
        if let old = p.frame, old != f { clock.boost(0.4) }   // it moved: follow every frame for a moment
        p.frame = f
        if p.isFinder {
            if (p.slotWidth == 0 || abs(f.width - p.slotWidth) > 0.5) && Date().timeIntervalSince(lastSlotMeasure) > 0.15 {
                measureSlot(p, frame: f)
            }
            if let slot = p.wideSlot ?? p.slot { bar.place(in: slot, ofWindow: f) } else { bar.place(near: f) }
        } else {
            bar.place(near: f)
        }
        bar.show()
        // Fallback for dialogs whose app doesn't send change notifications: a cheap look at the pop-up.
        if !p.isFinder, !scanning, !navigating, Date().timeIntervalSince(lastPoll) > 0.4 {
            lastPoll = Date()
            if let pop = p.popup, AX.string(pop, kAXValueAttribute) != p.popupValue { scanLocation() }
        }
    }

    private func measureSlot(_ p: FilePanel, frame f: CGRect) {
        lastSlotMeasure = Date()
        let firstTime = p.slotWidth == 0
        let slots = PanelFinder.toolbarSlot(window: p.element, frame: f)
        p.slot = slots?.normal
        p.wideSlot = slots?.wide
        p.titleRect = slots?.title
        p.slotWidth = f.width
        if firstTime {
            if let s = p.wideSlot { log("Finder toolbar slot: x=\(Int(s.minX)) y=\(Int(s.minY)) \(Int(s.width))x\(Int(s.height)) in \(Int(f.width))-wide window") }
            else { log("Finder toolbar slot: none (window \(Int(f.width)) wide), docking above") }
        }
    }

    // MARK: Finder: click the title to show the bar

    /// Where the title is on screen right now (Accessibility coordinates).
    private func titleArea(_ p: FilePanel) -> CGRect? {
        if p.windowID == nil { matchWindow(p) }
        guard let f = p.windowID.flatMap(WindowServer.frame(of:)) ?? AX.frame(p.element) else { return nil }
        p.frame = f
        if p.slotWidth == 0 || abs(f.width - p.slotWidth) > 0.5 { measureSlot(p, frame: f) }
        return (p.titleRect ?? p.slot)?.offsetBy(dx: f.minX, dy: f.minY)
    }

    private func reveal() {
        guard let p = panel, p.isFinder, !p.revealed else { return }
        p.revealed = true
        bar.setPath(p.path, name: p.popupValue, force: true)
        frameTick()
        clock.start()
        bar.focusField()
        scanLocation()      // refreshes the path if Finder moved on since the last look
    }

    private func conceal() {
        guard let p = panel, p.isFinder, p.revealed else { return }
        p.revealed = false
        bar.hide()
        clock.stop()
    }

    private func globalMouse(_ e: NSEvent) {
        guard let p = panel, let top = NSScreen.screens.first?.frame.maxY else { return }
        let m = NSEvent.mouseLocation
        let point = CGPoint(x: m.x, y: top - m.y)      // Accessibility coordinates
        if e.type == .leftMouseDown {
            mouseDown = (point, Date())
            clock.boost(0.3)        // maybe starting to drag the window: follow every frame while held
            if p.isFinder {
                if p.revealed { conceal() }             // a click anywhere outside the bar closes it
            } else if bar.visible {
                hideIfClosingClick(p, at: point)
            }
            return
        }
        // Mouse up: a plain click (not a drag) on the Finder window's title shows the bar.
        guard e.type == .leftMouseUp, p.isFinder, !p.revealed, frontPid() == p.pid,
              let down = mouseDown, hypot(down.point.x - point.x, down.point.y - point.y) < 5,
              Date().timeIntervalSince(down.time) < 0.6,
              let area = titleArea(p), area.contains(point) else { return }
        reveal()
    }

    /// Hides the dialog bar at once when you click the dialog's Save/Cancel (the dialog is closing).
    private func hideIfClosingClick(_ p: FilePanel, at point: CGPoint) {
        let element = p.element
        scanQueue.async {
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
                  let hit else { return }
            let buttons = [kAXDefaultButtonAttribute, kAXCancelButtonAttribute].compactMap { AX.element(element, $0) }
            let parent = AX.element(hit, kAXParentAttribute)
            let isButton = { (button: AXUIElement) -> Bool in
                CFEqual(button, hit) || (parent.map { CFEqual(button, $0) } ?? false)
            }
            guard buttons.contains(where: isButton) else { return }
            DispatchQueue.main.async {
                self.hiddenUntil = Date().addingTimeInterval(0.6)
                self.bar.hide()
            }
        }
    }

    private func dropPanel() {
        guard let p = panel else { return }
        if let path = p.path, !p.isFinder {
            addRecent(path)
            if let bid = NSRunningApplication(processIdentifier: p.pid)?.bundleIdentifier {
                var map = defaults.dictionary(forKey: "lastByApp") as? [String: String] ?? [:]
                map[bid] = path
                defaults.set(map, forKey: "lastByApp")
            }
        }
        log("\(p.isFinder ? "Finder window" : "dialog") gone (last folder: \(p.path ?? "unknown"))")
        panel = nil
        panelWatcher = nil
        clock.stop()
        bar.hide()
    }

    private func scanLocation() {
        guard let p = panel, !scanning else { return }
        scanning = true
        lastScan = Date()
        let previous = p.path
        if p.isFinder {
            let rec = recents
            scanQueue.async {
                let r = Location.finderFolder(p.element, previous: previous, recents: rec)
                DispatchQueue.main.async {
                    self.scanning = false
                    self.lastScan = Date()
                    guard self.panel === p else { return }
                    if r.path != p.path { log("Finder folder: \(r.path ?? "unknown") (title \"\(r.title ?? "-")\", \(r.urls) item URLs)") }
                    p.popupValue = r.title
                    p.path = r.path
                    self.bar.setPath(r.path, name: r.title)
                    p.unknownScans = r.path == nil ? p.unknownScans + 1 : 0
                    if p.unknownScans >= 3 && !p.dumped {
                        p.dumped = true
                        self.writeDump(p, reason: "Finder folder unknown")
                    }
                }
            }
            return
        }
        // Hints for the small Save dialog, which only shows the folder's name.
        var rec = [String]()
        if let bid = NSRunningApplication(processIdentifier: p.pid)?.bundleIdentifier {
            if let last = (defaults.dictionary(forKey: "lastByApp") as? [String: String])?[bid] { rec.append(last) }
            if let root = CFPreferencesCopyAppValue("NSNavLastRootDirectory" as CFString, bid as CFString) as? String {
                rec.append((root as NSString).expandingTildeInPath)
            }
        }
        rec += recents
        scanQueue.async {
            let s = Location.scan(p.element)
            let pop = Location.folderPopup(s)
            let path = Location.resolve(name: pop?.value, urls: s.urls, document: s.document, previous: previous, recents: rec)
            DispatchQueue.main.async {
                self.scanning = false
                self.lastScan = Date()
                guard self.panel === p else { return }
                if let el = pop?.element, !p.popupWatched || !(p.popup.map { CFEqual($0, el) } ?? false) {
                    self.panelWatcher?.watch(el, [kAXValueChangedNotification])
                    p.popupWatched = true
                }
                p.popup = pop?.element
                p.popupValue = pop?.value
                if path != p.path || p.path == nil && !p.dumped {
                    log("folder: \(path ?? "unknown") (pop-up \"\(pop?.value ?? "-")\", \(s.urls.count) item URLs, \(s.popups.count) pop-ups)")
                }
                p.path = path
                self.bar.setPath(path, name: pop?.value)
                p.unknownScans = path == nil ? p.unknownScans + 1 : 0
                if p.unknownScans >= 3 && !p.dumped {
                    p.dumped = true
                    self.writeDump(p, reason: "folder unknown")
                }
            }
        }
    }

    // MARK: Moving the dialog

    private func navigate(_ target: String, selectFile: Bool = false) {
        guard let p = panel else { return }
        guard !navigating else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDir) else {
            log("go: no such folder \(target)")
            bar.flashError()
            return
        }
        let folder = isDir.boolValue ? target : (target as NSString).deletingLastPathComponent
        let goal = (isDir.boolValue || !selectFile) ? folder : target
        navigating = true
        bar.setPath(folder, name: nil, force: true)
        if p.isFinder { conceal() } else { bar.releaseKeyFocus() }
        Navigator.go(to: goal, panel: p) { ok, note in
            self.navigating = false
            log("go \(goal): \(ok ? "ok" : "FAILED") (\(note))")
            if ok {
                if self.panel === p { p.path = folder }
                self.addRecent(folder)
            } else {
                self.bar.setPath(p.path, name: p.popupValue, force: true)
                self.bar.flashError()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.scanLocation() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.scanLocation() }
        }
    }

    private func addRecent(_ path: String) {
        var r = recents.filter { $0 != path }
        r.insert(path, at: 0)
        recents = r
    }

    // MARK: BarDelegate

    func barGo(_ text: String) {
        guard let path = PathText.normalize(text, relativeTo: panel?.path) else { bar.flashError(); return }
        navigate(path, selectFile: panel?.kind != "save")
    }

    func barUp() {
        if let p = panel, p.isFinder, !navigating {
            // Finder's own "Enclosing Folder" (⌘↑) keeps its history and selects the folder you came from.
            // The bar stays open (without the keyboard) so you can press ↑ again and watch the path.
            navigating = true
            bar.releaseKeyFocus()
            Navigator.press(Keys.up, flags: .maskCommand, panel: p) {
                self.navigating = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.scanLocation() }
            }
            return
        }
        guard let cur = panel?.path, cur != "/" else { NSSound.beep(); return }
        navigate((cur as NSString).deletingLastPathComponent)
    }

    func barCopy() {
        guard let path = panel?.path else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        bar.flashCopied()
    }

    func barCancelEditing() {
        if panel?.isFinder == true { conceal() } else { bar.releaseKeyFocus() }
        if let p = panel { _ = AX.set(p.app, kAXFrontmostAttribute, kCFBooleanTrue as CFTypeRef) }
    }

    func barDrop(_ url: URL) {
        navigate(url.path, selectFile: panel?.kind != "save")
    }

    func barMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let finder = finderFolders()
        if !finder.isEmpty {
            menu.addItem(header("Open in Finder"))
            for f in finder { menu.addItem(folderItem(f)) }
            menu.addItem(.separator())
        }
        let rec = recents.filter { FileManager.default.fileExists(atPath: $0) && !finder.contains($0) }
        menu.addItem(header(rec.isEmpty ? "No recent folders yet" : "Recent"))
        for f in rec.prefix(12) { menu.addItem(folderItem(f)) }
        if let cur = panel?.path {
            menu.addItem(.separator())
            let show = NSMenuItem(title: "Show This Folder in Finder", action: #selector(revealCurrent), keyEquivalent: "")
            show.target = self
            show.representedObject = cur
            menu.addItem(show)
        }
        return menu
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func folderItem(_ path: String) -> NSMenuItem {
        let name = FileManager.default.displayName(atPath: path)
        let item = NSMenuItem(title: name, action: #selector(menuGo(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = path
        item.toolTip = path
        let parent = ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        let title = NSMutableAttributedString(string: name, attributes: [.font: NSFont.menuFont(ofSize: 13)])
        title.append(NSAttributedString(string: "   " + parent, attributes: [
            .font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        item.attributedTitle = title
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        return item
    }

    @objc private func menuGo(_ item: NSMenuItem) {
        if let path = item.representedObject as? String { navigate(path) }
    }

    @objc private func revealCurrent(_ item: NSMenuItem) {
        if let path = item.representedObject as? String {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        }
    }

    /// Folders of the open Finder windows (asks once for permission to talk to Finder).
    private func finderFolders() -> [String] {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").isEmpty else { return [] }
        let source = """
        set out to ""
        tell application "Finder"
            repeat with w in (every Finder window)
                try
                    set out to out & POSIX path of (target of w as alias) & linefeed
                end try
            end repeat
        end tell
        return out
        """
        var err: NSDictionary?
        guard let text = NSAppleScript(source: source)?.executeAndReturnError(&err).stringValue else {
            if let err { log("Finder windows: \(err[NSAppleScript.errorMessage] ?? err)") }
            return []
        }
        var out = [String]()
        for line in text.split(separator: "\n") {
            var p = String(line)
            if p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            if !out.contains(p) { out.append(p) }
        }
        return out
    }

    // MARK: Menu bar icon

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let symbol = !trusted ? "exclamationmark.triangle" : (enabled ? "folder" : "folder.badge.minus")
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "PathBar")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.toolTip = "PathBar – path bar for Save and Open dialogs"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let title: String
        if !trusted { title = "Needs Accessibility permission" }
        else if !enabled { title = "Paused" }
        else if let p = panel { title = "\(p.isFinder ? "Finder" : "Dialog"): \(p.path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "folder unknown")" }
        else { title = "Waiting for a Save or Open dialog" }
        menu.addItem(header("PathBar — \(title)"))
        menu.addItem(.separator())
        if !trusted {
            let grant = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(openAccessibility), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }
        let toggle = NSMenuItem(title: "Show Path Bar in Dialogs", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)
        let finderToggle = NSMenuItem(title: "Show Path Bar in Finder Windows", action: #selector(toggleFinder), keyEquivalent: "")
        finderToggle.target = self
        finderToggle.state = finderEnabled ? .on : .off
        menu.addItem(finderToggle)
        let dump = NSMenuItem(title: "Write Diagnostic Dump", action: #selector(dumpFront), keyEquivalent: "")
        dump.target = self
        menu.addItem(dump)
        let logItem = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit PathBar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleEnabled() { enabled.toggle(); if !enabled { dropPanel() }; updateStatusIcon() }
    @objc private func openAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func toggleFinder() {
        finderEnabled.toggle()
        if !finderEnabled, panel?.isFinder == true { conceal(); dropPanel() }
    }
    @objc private func openLog() { NSWorkspace.shared.open(logURL) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func dumpFront() { writeDump(panel, reason: "menu") }

    // MARK: Diagnostics

    private func writeDump(_ p: FilePanel?, reason: String) {
        let front = frontPid().flatMap { NSRunningApplication(processIdentifier: $0) }
        scanQueue.async {
            var text = ""
            if let p {
                text = Dumper.dump(p.element, app: p.app, title: "dialog kind=\(p.kind) pid=\(p.pid) (\(reason))")
            } else if let front {
                let app = AXUIElementCreateApplication(front.processIdentifier)
                text = "No dialog tracked; front app \(front.localizedName ?? "?") (\(reason))\n"
                if let w = AX.element(app, kAXFocusedWindowAttribute) {
                    text += Dumper.dump(w, app: app, title: "focused window")
                    for s in PanelFinder.sheets(of: w) { text += Dumper.dump(s, app: nil, title: "sheet") }
                }
            }
            try? text.write(to: dumpURL, atomically: true, encoding: .utf8)
            DispatchQueue.main.async { log("wrote diagnostic dump (\(reason)) to \(dumpURL.path)") }
        }
    }

    /// Test hooks: `local.pathbar.cmd` distributed notification with object "dump", "state", "up" or "go:/some/path".
    @objc private func debugCommand(_ note: Notification) {
        guard let cmd = note.object as? String else { return }
        log("command: \(cmd)")
        if cmd == "dump" { writeDump(panel, reason: "command") }
        else if cmd == "up" { barUp() }
        else if cmd.hasPrefix("pid:") { forcedPid = pid_t(cmd.dropFirst(4)); dropPanel() }
        else if cmd == "focus" { if panel?.isFinder == true { reveal() } else { bar.focusField() } }
        else if cmd == "blur" { barCancelEditing() }
        else if cmd == "close", let p = panel {
            // Presses the window's close button (Finder) or Cancel (dialogs), to time how fast the bar goes.
            // Pressed off the main thread: the call waits for the app, and the bar must keep updating meanwhile.
            let element = p.element, attr = p.isFinder ? kAXCloseButtonAttribute : kAXCancelButtonAttribute
            scanQueue.async {
                if let button = AX.element(element, attr) { AXUIElementPerformAction(button, kAXPressAction as CFString) }
            }
        }
        else if cmd == "snap" { bar.snapshot(to: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/PathBar-snap.png")) }
        else if cmd.hasPrefix("go:") { barGo(String(cmd.dropFirst(3))) }
        else if cmd.hasPrefix("dumpapp:") {
            // Dump the windows of any app by bundle id, without it having to be in front.
            let bid = String(cmd.dropFirst(8))
            guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first else { return }
            scanQueue.async {
                let app = AXUIElementCreateApplication(target.processIdentifier)
                var text = "windows of \(bid)\n"
                for (i, w) in AX.elements(app, kAXWindowsAttribute).prefix(3).enumerated() {
                    text += Dumper.dump(w, app: i == 0 ? app : nil, title: "window \(i)")
                }
                try? text.write(to: dumpURL, atomically: true, encoding: .utf8)
                DispatchQueue.main.async { log("wrote app dump for \(bid)") }
            }
        }
        else if cmd == "state" {
            let f = bar.panel.frame
            log("state: trusted=\(trusted) enabled=\(enabled) dialog=\(panel.map { "\($0.kind) pid \($0.pid)" } ?? "none") path=\(panel?.path ?? "-") popup=\(panel?.popupValue ?? "-") bar=\(bar.visible ? "visible" : "hidden") at \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))")
        }
    }
}

// MARK: - Self test (pure logic only)

func selfTest() -> Bool {
    var ok = true
    func check(_ cond: Bool, _ what: String) { if !cond { ok = false; print("FAIL: \(what)") } }
    let home = NSHomeDirectory()
    check(PathText.normalize("  ~/Documents ", relativeTo: nil) == home + "/Documents", "tilde")
    check(PathText.normalize("\"/Users/x/My Folder\"", relativeTo: nil) == "/Users/x/My Folder", "quotes")
    check(PathText.normalize("/Users/x/My\\ Folder", relativeTo: nil) == "/Users/x/My Folder", "escaped space")
    check(PathText.normalize("file:///Users/x/A%20B", relativeTo: nil) == "/Users/x/A B", "file URL")
    check(PathText.normalize("sub", relativeTo: "/tmp/a") == "/tmp/a/sub", "relative")
    check(PathText.normalize("..", relativeTo: "/tmp/a") == "/tmp", "dot dot")
    check(PathText.normalize("sub", relativeTo: nil) == nil, "relative without folder")

    let tmp = NSTemporaryDirectory() + "pathbar-test-\(getpid())"
    let fm = FileManager.default
    try? fm.createDirectory(atPath: tmp + "/Alpha One/Inner", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: tmp + "/Alpha Two", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: tmp + "/Beta", withIntermediateDirectories: true)
    fm.createFile(atPath: tmp + "/Beta/file.srt", contents: Data())
    defer { try? fm.removeItem(atPath: tmp) }
    let t = (tmp as NSString).resolvingSymlinksInPath
    check(PathText.complete(t + "/be") == t + "/Beta/", "complete unique")
    check(PathText.complete(t + "/al") == t + "/Alpha ", "complete common prefix")
    check(PathText.complete(t + "/zz") == nil, "complete none")

    let col1 = [URL(fileURLWithPath: t + "/Alpha One"), URL(fileURLWithPath: t + "/Beta")]
    let col2 = [URL(fileURLWithPath: t + "/Beta/file.srt")]
    check(Location.resolve(name: "Beta", urls: col1 + col2, document: nil, previous: nil, recents: []) == t + "/Beta", "column view")
    check(Location.resolve(name: (t as NSString).lastPathComponent, urls: col1, document: nil, previous: nil, recents: []) == t, "list view")
    check(Location.resolve(name: "Inner", urls: [], document: nil, previous: t + "/Alpha One", recents: []) == t + "/Alpha One/Inner", "empty child")
    check(Location.resolve(name: "Alpha One", urls: [], document: nil, previous: t + "/Alpha One/Inner", recents: []) == t + "/Alpha One", "went up")
    check(Location.resolve(name: nil, urls: col2, document: nil, previous: nil, recents: []) == t + "/Beta", "no name")
    try? fm.createDirectory(atPath: t + "/Same/Same", withIntermediateDirectories: true)
    let nested = [URL(fileURLWithPath: t + "/Same/Same"), URL(fileURLWithPath: t + "/Alpha One")]
    check(Location.resolve(name: "Same", urls: [nested[0]], document: nil, previous: nil, recents: []) == t + "/Same", "same-name sub-folder")
    check(Location.resolve(name: "Beta", urls: [URL(fileURLWithPath: t + "/Beta"), nested[1]], document: nil, previous: nil, recents: []) == t + "/Beta", "empty folder in column view")
    print(ok ? "selftest ok" : "selftest FAILED")
    return ok
}

if CommandLine.arguments.contains("--selftest") { exit(selfTest() ? 0 : 1) }

let me = NSRunningApplication.current
if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.pathbar")
    .contains(where: { $0.processIdentifier != me.processIdentifier }) {
    print("PathBar is already running")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
controller.start()
app.run()
