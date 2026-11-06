import AppKit

// Turns the artwork (icon-source.png) into the 1024×1024 app icon on Apple's grid: the tile
// fitted into the central 824 px with a soft shadow, transparent around it.
// Usage: swiftc make-icon.swift -o make-icon && ./make-icon icon-source.png icon-1024.png

let args = CommandLine.arguments
let src = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: args[1])))!
let w = src.pixelsWide, h = src.pixelsHigh

// Bounds of the visible tile (ignore transparent and near-transparent pixels).
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h { for x in 0..<w where src.colorAt(x: x, y: y)!.alphaComponent > 0.5 {
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
let tile = src.cgImage!.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!

let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
let scale = 824 / CGFloat(max(tile.width, tile.height))
let size = NSSize(width: CGFloat(tile.width) * scale, height: CGFloat(tile.height) * scale)
let rect = NSRect(x: (1024 - size.width) / 2, y: (1024 - size.height) / 2 + 6, width: size.width, height: size.height)
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.30)
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowBlurRadius = 24
shadow.set()
NSGraphicsContext.current!.imageInterpolation = .high
NSImage(cgImage: tile, size: size).draw(in: rect)
NSGraphicsContext.restoreGraphicsState()
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("tile \(tile.width)x\(tile.height) -> \(Int(size.width))x\(Int(size.height)) on 1024")
