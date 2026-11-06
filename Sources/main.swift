import AppKit
import ApplicationServices
import ServiceManagement

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
    /// Last look at the front app's windows (window server); the app is only asked when this changes.
    private var lastSnapshot: WindowServer.Snapshot?
    private var findRetries = 0
    private var lastFind = Date.distantPast
    private var lastTrustCheck = Date.distantPast
    /// Looks at the window list 4×/s for a moment after a click or app switch (when dialogs appear),
    /// and once a second otherwise.
    private var busyUntil = Date.distantPast
    private var lastLook = Date.distantPast
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

    /// Installed by install.sh: its LaunchAgent starts PathBar at login, so the app doesn't register itself.
    private var startedByInstallScript: Bool { ProcessInfo.processInfo.environment["PATHBAR_LAUNCHD"] != nil }

    func start() {
        guard runningFromApplications() else { return }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        bar.delegate = self
        setupStatusItem()
        registerLoginItemOnce()
        trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        updateStatusIcon()      // the icon was drawn before the permission was known
        log("started (pid \(getpid())), accessibility \(trusted ? "granted" : "NOT granted yet")")

        // Watches window changes through the window server (free for other apps).
        let slow = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(slow, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // Clicks in other apps: Finder title clicks show the bar, clicks elsewhere hide it.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] e in self?.globalMouse(e) }

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
        // Hide right away when you switch apps; don't wait for the next look.
        if let p = panel {
            if frontPid() != p.pid {
                if p.isFinder { conceal() } else { bar.hide(); clock.stop() }
            } else if !p.isFinder {
                clock.start()
            }
        }
        lastSnapshot = nil      // a different app: look at its windows afresh
        scheduleCheck()
    }

    /// Runs `check()` once soon, however many triggers arrive together.
    private func scheduleCheck() {
        busyUntil = Date().addingTimeInterval(1.5)
        guard !checkPending else { return }
        checkPending = true
        DispatchQueue.main.async { self.checkPending = false; self.check() }
    }

    /// Four times a second: a look at the front app's windows through the window server, which
    /// costs the app nothing. Only when a new window appears (or another one comes to the front)
    /// is the app asked, once, whether it's a Save/Open dialog. Apps are never polled.
    private func check() {
        if Date().timeIntervalSince(lastTrustCheck) > 3 {
            lastTrustCheck = Date()
            let nowTrusted = AXIsProcessTrusted()
            if nowTrusted != trusted {
                trusted = nowTrusted
                log("accessibility \(trusted ? "granted" : "revoked")")
                updateStatusIcon()
            }
        }
        guard enabled, trusted, let pid = frontPid() else { dropPanel(); return }
        if pid == getpid() { return }
        let now = Date()
        if now >= busyUntil && findRetries == 0 && now.timeIntervalSince(lastLook) < 1 { return }   // quiet: once a second
        lastLook = now
        let snap = WindowServer.snapshot(pid: pid)

        if let p = panel {
            var keep: Bool
            if p.pid != pid {
                keep = false
            } else if navigating {
                keep = true
            } else if let id = p.windowID {
                // Still on screen, and (Finder) still the front window? Typing in the bar doesn't count as leaving.
                keep = snap.ids.contains(id) && (!p.isFinder || snap.front == id || bar.panel.isKeyWindow)
            } else {
                keep = AX.isAlive(p.element)      // rare: window couldn't be matched, so ask the app
            }
            if keep {
                lastSnapshot = snap
                if (!p.isFinder || p.revealed) && !clock.running { clock.start() }
                // Dialogs: a rare safety re-read (changes arrive as notifications, plus the pop-up check).
                if !p.isFinder && !scanning && !navigating && Date().timeIntervalSince(lastScan) > 15 { scanLocation() }
                return
            }
            dropPanel()
            lastSnapshot = nil
        }

        if snap != lastSnapshot {
            lastSnapshot = snap
            findRetries = 3          // a dialog may still be animating in: allow a couple more tries
        }
        guard findRetries > 0, !finding, Date().timeIntervalSince(lastFind) > 0.25 else { return }
        findRetries -= 1
        lastFind = Date()
        finding = true
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        let wantFinder = finderEnabled && NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.finder"
        scanQueue.async {
            let found = PanelFinder.find(pid: pid) ?? (wantFinder ? PanelFinder.findFinderWindow(pid: pid) : nil)
            DispatchQueue.main.async {
                self.finding = false
                guard let found, self.panel == nil, self.frontPid() == found.pid else { return }
                self.findRetries = 0
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
        // Dialogs: read the folder now (the bar is visible). Finder: only when you click the title.
        if p.isFinder { p.stale = true } else { scanLocation() }
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
            // Finder with the bar hidden: just note it; the path is read when you click the title.
            if p.isFinder && !p.revealed { p.stale = true; return }
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
        if p.stale { p.stale = false; p.path = nil; p.popupValue = AX.string(p.element, kAXTitleAttribute) }
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
        busyUntil = Date().addingTimeInterval(1.5)     // a click may open a dialog: look closely for a moment
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
                let before = AX.calls
                let r = Location.finderFolder(p.element, previous: previous, recents: rec)
                DispatchQueue.main.async {
                    self.scanning = false
                    self.lastScan = Date()
                    guard self.panel === p else { return }
                    if r.path != p.path { log("Finder folder: \(r.path ?? "unknown") (title \"\(r.title ?? "-")\", \(r.urls) item URLs, \(AX.calls - before) requests)") }
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
            let before = AX.calls
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
                    log("folder: \(path ?? "unknown") (pop-up \"\(pop?.value ?? "-")\", \(s.urls.count) item URLs, \(s.popups.count) pop-ups, \(AX.calls - before) requests)")
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
        if !startedByInstallScript {
            let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
            login.target = self
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }
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

    // MARK: Installed from the DMG

    /// Opened straight from the disk image (or a quarantined Downloads copy macOS runs from a
    /// temporary place): ask to move it to Applications first, so the login item and the
    /// Accessibility permission point at the right copy.
    private func runningFromApplications() -> Bool {
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") else { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move PathBar to Applications first"
        alert.informativeText = "Drag PathBar into the Applications folder (in the window it came in), then open it from Applications."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
        return false
    }

    /// First start of a DMG install: start at login from now on (shown in System Settings > Login Items).
    private func registerLoginItemOnce() {
        guard !startedByInstallScript, !defaults.bool(forKey: "loginItemSet") else { return }
        defaults.set(true, forKey: "loginItemSet")
        do { try SMAppService.mainApp.register(); log("added to login items") }
        catch { log("couldn't add login item: \(error.localizedDescription)") }
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            log("login item change failed: \(error.localizedDescription)")
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
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
        else if cmd.hasPrefix("cmdkey:"), let code = CGKeyCode(cmd.dropFirst(7)) {
            // A real ⌘-keypress to test shortcuts in the bar; only when the bar has the keyboard,
            // so it can never land in another app.
            if bar.panel.isKeyWindow { Keys.post(code, flags: .maskCommand, to: nil) } else { log("cmdkey ignored: bar not focused") }
        }
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
        else if cmd == "axcount" { log("Accessibility requests sent so far: \(AX.calls)") }
        else if cmd == "probefinder", let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            // Cost of reading the folder of Finder's frontmost window (needs no focus change).
            scanQueue.async {
                let app = AXUIElementCreateApplication(finder.processIdentifier)
                guard let w = AX.elements(app, kAXWindowsAttribute).first(where: { AX.string($0, "AXIdentifier") == "FinderWindow" }) else {
                    DispatchQueue.main.async { log("probefinder: no Finder window on this Space") }; return
                }
                let before = AX.calls
                let r = Location.finderFolder(w, previous: nil, recents: [])
                let n = AX.calls - before
                DispatchQueue.main.async { log("probefinder: \(r.path ?? "unknown") in \(n) requests") }
            }
        }
        else if cmd == "probefind", let pid = frontPid() {
            // How many requests one dialog search costs in the front app (the old code did this every 0.5 s).
            scanQueue.async {
                let before = AX.calls
                _ = PanelFinder.find(pid: pid)
                let n = AX.calls - before
                DispatchQueue.main.async { log("one dialog search in pid \(pid) = \(n) requests") }
            }
        }
        else if cmd == "state" {
            let f = bar.panel.frame
            log("state: trusted=\(trusted) enabled=\(enabled) dialog=\(panel.map { "\($0.kind) pid \($0.pid)" } ?? "none") path=\(panel?.path ?? "-") popup=\(panel?.popupValue ?? "-") bar=\(bar.visible ? "visible" : "hidden") text=[\(bar.field.stringValue)] at \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))")
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
