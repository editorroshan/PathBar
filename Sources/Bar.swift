import AppKit

// The floating address bar that sits on top of a Save / Open dialog.

protocol BarDelegate: AnyObject {
    func barGo(_ text: String)
    func barUp()
    func barCopy()
    func barMenu() -> NSMenu
    func barCancelEditing()
    func barDrop(_ url: URL)
}

final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Buttons react to the first click even though PathBar is never the active app.
final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class PathField: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// One click selects the whole path, like an address bar.
    override func mouseDown(with event: NSEvent) {
        let wasEditing = currentEditor() != nil
        super.mouseDown(with: event)
        if !wasEditing, let editor = currentEditor(), editor.selectedRange.length == 0 {
            editor.selectAll(nil)
        }
    }
}

/// Background that also accepts folders dragged in from Finder.
final class DropView: NSVisualEffectView {
    var onDrop: ((URL) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURL(sender) != nil ? .generic : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let u = fileURL(sender) else { return false }
        onDrop?(u)
        return true
    }
    private func fileURL(_ info: NSDraggingInfo) -> URL? {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first
    }
}

final class Bar: NSObject, NSTextFieldDelegate {
    static let height: CGFloat = 38

    let panel: BarPanel
    let field = PathField()
    private let up = FirstClickButton()
    private let copy = FirstClickButton()
    private let more = FirstClickButton()
    private let background = DropView()
    weak var delegate: BarDelegate?
    private var shownPath: String?
    private(set) var visible = false
    private var lastFrame = NSRect.zero
    private var stack: NSStackView!

    /// Finder windows: sits inside the toolbar at normal float level, no shadow.
    /// Dialogs: floats above the dialog, above everything.
    var finderMode = false {
        didSet {
            guard finderMode != oldValue else { return }
            panel.level = finderMode ? .floating : NSWindow.Level(rawValue: NSWindow.Level.modalPanel.rawValue + 1)
            panel.hasShadow = !finderMode
            background.blendingMode = finderMode ? .withinWindow : .behindWindow
            background.layer?.cornerRadius = finderMode ? 8 : 11
            background.layer?.borderWidth = finderMode ? 0 : 1
            stack.edgeInsets = finderMode ? NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 4)
                                          : NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
            lastFrame = .zero
        }
    }

    var isEditing: Bool { panel.isKeyWindow && field.currentEditor() != nil }

    override init() {
        panel = BarPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: Bar.height),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.modalPanel.rawValue + 1)
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]

        background.material = .windowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 11
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        background.registerForDraggedTypes([.fileURL])
        background.onDrop = { [weak self] u in self?.delegate?.barDrop(u) }
        panel.contentView = background

        style(up, symbol: "arrow.up", tip: "Up one folder")
        up.wantsLayer = true
        up.layer?.backgroundColor = NSColor.systemBlue.cgColor
        up.layer?.cornerRadius = 7
        up.contentTintColor = .white
        up.action = #selector(upPressed)

        style(copy, symbol: "doc.on.doc", tip: "Copy this path")
        copy.contentTintColor = .secondaryLabelColor
        copy.action = #selector(copyPressed)

        style(more, symbol: "clock.arrow.circlepath", tip: "Recent folders and open Finder windows")
        more.contentTintColor = .secondaryLabelColor
        more.action = #selector(morePressed)

        field.font = .systemFont(ofSize: 13)
        field.bezelStyle = .roundedBezel
        field.isBezeled = true
        field.focusRingType = .default
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingHead
        field.placeholderString = "Type or paste a folder path, then press Return"
        field.delegate = self
        field.unregisterDraggedTypes()

        stack = NSStackView(views: [up, field, copy, more])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            up.widthAnchor.constraint(equalToConstant: 30), up.heightAnchor.constraint(equalToConstant: 26),
            copy.widthAnchor.constraint(equalToConstant: 26), copy.heightAnchor.constraint(equalToConstant: 26),
            more.widthAnchor.constraint(equalToConstant: 26), more.heightAnchor.constraint(equalToConstant: 26),
        ])
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func style(_ b: NSButton, symbol: String, tip: String) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(cfg)
        b.imagePosition = .imageOnly
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.toolTip = tip
        b.target = self
        b.setButtonType(.momentaryChange)
    }

    // MARK: Showing

    /// Docks the bar just above the dialog (below it if there's no room above).
    func place(near ax: CGRect) {
        guard let primary = NSScreen.screens.first else { return }
        let top = primary.frame.maxY
        let dlg = NSRect(x: ax.minX, y: top - ax.maxY, width: ax.width, height: ax.height)
        let h = Bar.height, gap: CGFloat = 6
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: dlg.midX, y: dlg.maxY - 2)) } ?? NSScreen.main ?? primary
        let vis = screen.visibleFrame
        let w = min(max(dlg.width, 480), vis.width)
        var y = dlg.maxY + gap
        if y + h > vis.maxY {
            y = dlg.minY - gap - h
            if y < vis.minY { y = dlg.maxY - h - gap }
        }
        var x = dlg.midX - w / 2
        x = min(max(x, vis.minX), vis.maxX - w)
        let f = NSRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h)
        if f != lastFrame {
            lastFrame = f
            panel.setFrame(f, display: true)
        }
    }

    /// Finder: puts the bar in the toolbar slot (relative to the window's top-left, AX coordinates).
    func place(in slot: CGRect, ofWindow ax: CGRect) {
        guard let primary = NSScreen.screens.first else { return }
        let r = slot.offsetBy(dx: ax.minX, dy: ax.minY)
        let f = NSRect(x: r.minX.rounded(), y: (primary.frame.maxY - r.maxY).rounded(),
                       width: r.width.rounded(), height: r.height.rounded())
        if f != lastFrame {
            // Growing or shrinking in place (start/stop typing) is animated; following the window is not.
            let resizeOnly = f.origin == lastFrame.origin && abs(f.width - lastFrame.width) > 20 && visible
            lastFrame = f
            if resizeOnly {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.16
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(f, display: true)
                }
            } else {
                panel.setFrame(f, display: true)
            }
        }
    }

    func show() {
        guard !visible else { return }
        visible = true
        panel.orderFrontRegardless()
    }

    func hide() {
        guard visible else { return }
        visible = false
        if field.currentEditor() != nil { panel.makeFirstResponder(nil) }
        panel.orderOut(nil)
    }

    /// Hands the keyboard back to the dialog (we only keep it while you type a path).
    func releaseKeyFocus() {
        guard panel.isKeyWindow else { return }
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        if visible { panel.orderFrontRegardless() }
    }

    // MARK: Content

    func setPath(_ path: String?, name: String?, force: Bool = false) {
        if isEditing && !force { return }
        shownPath = path
        field.stringValue = path ?? name ?? ""
        field.textColor = path == nil ? .secondaryLabelColor : .labelColor
        up.isEnabled = path != nil && path != "/"
        up.alphaValue = up.isEnabled ? 1 : 0.45
        copy.isEnabled = path != nil
    }

    func flashError() {
        field.textColor = .systemRed
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.values = [0, -7, 6, -4, 3, 0]
        anim.duration = 0.32
        background.layer?.add(anim, forKey: "shake")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.field.textColor = self.shownPath == nil ? .secondaryLabelColor : .labelColor
        }
    }

    func flashCopied() {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        copy.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")?.withSymbolConfiguration(cfg)
        copy.contentTintColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            self.copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy this path")?.withSymbolConfiguration(cfg)
            self.copy.contentTintColor = .secondaryLabelColor
        }
    }

    /// Renders the bar into a PNG (debug aid; needs no screen-recording permission).
    func snapshot(to url: URL) {
        guard let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: Actions

    @objc private func upPressed() { delegate?.barUp() }
    @objc private func copyPressed() { delegate?.barCopy() }
    @objc private func morePressed() {
        guard let menu = delegate?.barMenu() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY + 6), in: more)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            delegate?.barGo(field.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            field.stringValue = shownPath ?? ""
            delegate?.barCancelEditing()
            return true
        case #selector(NSResponder.insertTab(_:)):
            if let done = PathText.complete(textView.string) {
                textView.string = done
                textView.setSelectedRange(NSRange(location: (done as NSString).length, length: 0))
            } else {
                NSSound.beep()
            }
            return true
        default:
            return false
        }
    }
}
