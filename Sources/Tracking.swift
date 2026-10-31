import AppKit
import ApplicationServices

// Cheap, low-latency ways to follow another app's window.

/// Window positions straight from the window server. No message goes to the app, so it never
/// lags when the app is busy, and it knows the moment a window closes or is hidden.
enum WindowServer {
    /// The window-server id of the app's on-screen window with this frame (top-left coordinates).
    static func windowID(pid: pid_t, frame ax: CGRect) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        var best: (id: CGWindowID, distance: CGFloat)?
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let r = bounds(w) else { continue }
            let d = abs(r.minX - ax.minX) + abs(r.minY - ax.minY) + abs(r.width - ax.width) + abs(r.height - ax.height)
            if d < 6, d < (best?.distance ?? .greatestFiniteMagnitude) { best = (id, d) }
        }
        return best?.id
    }

    /// The window's frame while it is on screen; nil once it is closed, minimised or hidden.
    static func frame(of id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let w = list.first,
              (w[kCGWindowIsOnscreen as String] as? Bool) == true else { return nil }
        return bounds(w)
    }

    private static func bounds(_ w: [String: Any]) -> CGRect? {
        guard let b = w[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: b as CFDictionary)
    }
}

/// Delivers an app's Accessibility notifications (window closed, title changed, …) on the main
/// thread, so PathBar reacts to changes instead of asking over and over.
final class AXWatcher {
    private var observer: AXObserver?
    var handler: ((String, AXUIElement) -> Void)?

    init?(pid: pid_t) {
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, name, refcon in
            guard let refcon else { return }
            Unmanaged<AXWatcher>.fromOpaque(refcon).takeUnretainedValue().handler?(name as String, element)
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return nil }
        observer = obs
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
    }

    func watch(_ element: AXUIElement, _ names: [String]) {
        guard let observer else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        for name in names { AXObserverAddNotification(observer, element, name as CFString, me) }
    }

    deinit {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }
}

/// Calls `tick` while started: once per screen refresh while things move (a window being dragged
/// or animating), and only 10 times a second while everything is still, to save CPU.
final class FrameClock: NSObject {
    private let tick: () -> Void
    private var link: AnyObject?
    private var timer: Timer?
    private(set) var running = false
    private var fast = false
    private var fastUntil = Date.distantPast

    init(_ tick: @escaping () -> Void) { self.tick = tick }

    func start() {
        guard !running else { return }
        running = true
        boost(0.6)          // windows usually animate in: follow closely at first
    }

    func stop() {
        running = false
        fast = false
        stopLink()
        stopTimer()
    }

    /// Follow every screen refresh for at least this long (and for as long as the mouse is held).
    func boost(_ seconds: TimeInterval) {
        guard running else { return }
        fastUntil = max(fastUntil, Date().addingTimeInterval(seconds))
        guard !fast else { return }
        fast = true
        stopTimer()
        if #available(macOS 14.0, *), let screen = NSScreen.main {
            let l = screen.displayLink(target: self, selector: #selector(frame))
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.frame() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    @objc private func frame() {
        tick()
        // Calm again (nothing held, boost over): drop to 10 checks a second.
        if running, fast, Date() > fastUntil, NSEvent.pressedMouseButtons & 1 == 0 {
            fast = false
            stopLink()
            stopTimer()
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func stopLink() {
        if #available(macOS 14.0, *), let l = link as? CADisplayLink { l.invalidate() }
        link = nil
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
