import AppKit

// Renders a simple, flat app icon: a rounded-square gradient background
// (blue -> a slightly deeper blue-purple, echoing the "gateway" idea)
// with a centered white glyph -- two overlapping rounded rects standing
// in for "swap between two things through one gate."

let size = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

let ctx = NSGraphicsContext.current!.cgContext

// Background: rounded square with a diagonal gradient.
let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
let cornerRadius: CGFloat = CGFloat(size) * 0.22
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
ctx.addPath(bgPath)
ctx.clip()

let colors = [
    NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.98, alpha: 1.0).cgColor,
    NSColor(calibratedRed: 0.36, green: 0.22, blue: 0.86, alpha: 1.0).cgColor,
]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: size, y: 0),
    options: []
)

// Glyph: two overlapping rounded rects (the "swap" idea), white, offset
// diagonally, with a small gap so they read as two distinct tiles.
let glyphColor = NSColor.white.withAlphaComponent(0.95)
glyphColor.setFill()

let tile = CGFloat(size) * 0.30
let radius = tile * 0.28
let offset = CGFloat(size) * 0.10
let center = CGFloat(size) / 2

let rect1 = CGRect(x: center - tile - offset * 0.4, y: center - offset, width: tile, height: tile)
let rect2 = CGRect(x: center - offset * 0.4 + offset, y: center - tile + offset, width: tile, height: tile)

let path1 = NSBezierPath(roundedRect: rect1, xRadius: radius, yRadius: radius)
let path2 = NSBezierPath(roundedRect: rect2, xRadius: radius, yRadius: radius)

NSColor.white.withAlphaComponent(0.55).setFill()
path1.fill()
NSColor.white.withAlphaComponent(0.95).setFill()
path2.fill()

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("failed to render icon")
}

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
