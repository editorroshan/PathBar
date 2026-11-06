import AppKit

// Draws the PathBar app icon (1024×1024 PNG) in the macOS style: a rounded tile with a blue
// gradient and a white "address bar" capsule holding the blue ↑ button and a path.
// Usage: swiftc make-icon.swift -o make-icon && ./make-icon icon.png

let S: CGFloat = 1024
let image = NSImage(size: NSSize(width: S, height: S))
image.lockFocus()

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: a)
}

// Tile (Apple's icon grid: 824 pt body inside 1024, generous corner radius) with a soft drop shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let tile = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
NSGraphicsContext.saveGraphicsState()
let drop = NSShadow()
drop.shadowColor = NSColor(white: 0, alpha: 0.32)
drop.shadowOffset = NSSize(width: 0, height: -14)
drop.shadowBlurRadius = 30
drop.set()
rgb(0x1E7BFF).setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
tile.addClip()
NSGradient(colors: [rgb(0x45D2FF), rgb(0x1C8BFF), rgb(0x1556E8)], atLocations: [0, 0.55, 1],
           colorSpace: .sRGB)!.draw(in: body, angle: -90)
// Soft light from the top left, like the glassy Big Sur icons.
NSGradient(starting: NSColor(white: 1, alpha: 0.30), ending: NSColor(white: 1, alpha: 0))!
    .draw(fromCenter: NSPoint(x: 330, y: 860), radius: 0, toCenter: NSPoint(x: 330, y: 860), radius: 620, options: [])
NSGraphicsContext.restoreGraphicsState()
// Thin inner edge.
NSColor(white: 1, alpha: 0.22).setStroke()
let edge = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 184, yRadius: 184)
edge.lineWidth = 3
edge.stroke()

// The address bar capsule.
let bar = NSRect(x: 160, y: 428, width: 704, height: 168)
let capsule = NSBezierPath(roundedRect: bar, xRadius: 84, yRadius: 84)
NSGraphicsContext.saveGraphicsState()
let lift = NSShadow()
lift.shadowColor = NSColor(srgbRed: 0, green: 0.12, blue: 0.4, alpha: 0.45)
lift.shadowOffset = NSSize(width: 0, height: -16)
lift.shadowBlurRadius = 34
lift.set()
NSColor.white.setFill()
capsule.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: rgb(0xFFFFFF), ending: rgb(0xE6EDF7))!.draw(in: capsule, angle: -90)

// Blue ↑ button.
let button = NSRect(x: 184, y: 452, width: 120, height: 120)
let round = NSBezierPath(ovalIn: button)
NSGraphicsContext.saveGraphicsState()
let glow = NSShadow()
glow.shadowColor = NSColor(srgbRed: 0, green: 0.3, blue: 0.9, alpha: 0.35)
glow.shadowOffset = NSSize(width: 0, height: -5)
glow.shadowBlurRadius = 10
glow.set()
rgb(0x0A84FF).setFill()
round.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: rgb(0x3FA5FF), ending: rgb(0x0A6CF0))!.draw(in: round, angle: -90)
let cfg = NSImage.SymbolConfiguration(pointSize: 64, weight: .heavy)
if let arrow = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let white = NSImage(size: arrow.size, flipped: false) { r in
        arrow.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
    }
    white.draw(in: NSRect(x: button.midX - arrow.size.width / 2, y: button.midY - arrow.size.height / 2,
                          width: arrow.size.width, height: arrow.size.height))
}

// The path.
let font = NSFont(descriptor: NSFont.systemFont(ofSize: 76, weight: .semibold).fontDescriptor.withDesign(.rounded)!, size: 76)!
let path = NSMutableAttributedString(string: "~", attributes: [.font: font, .foregroundColor: rgb(0x1F2A3A)])
path.append(NSAttributedString(string: " / ", attributes: [.font: font, .foregroundColor: rgb(0x8A97AB)]))
path.append(NSAttributedString(string: "Projects", attributes: [.font: font, .foregroundColor: rgb(0x1F2A3A)]))
path.draw(at: NSPoint(x: 336, y: bar.midY - path.size().height / 2 + 2))

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
