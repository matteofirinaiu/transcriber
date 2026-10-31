// Draws the Transcriber icon (a sound wave made of vertical bars) as a 1024×1024 PNG.
// Usage: swift scripts/make_icon.swift output.png
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon_1024.png"

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Icon body with the proportions of the macOS grid (824 px out of 1024) and a soft shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor(srgbRed: 0.84, green: 0.15, blue: 0.24, alpha: 1).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

let gradient = NSGradient(colors: [
    NSColor(srgbRed: 1.00, green: 0.42, blue: 0.40, alpha: 1),
    NSColor(srgbRed: 0.80, green: 0.12, blue: 0.27, alpha: 1),
])!
gradient.draw(in: shape, angle: -90)

// The sound wave: rounded white bars of different heights, centered on the icon.
NSColor.white.setFill()
let barWidth: CGFloat = 56
let spacing: CGFloat = 92
let heights: [CGFloat] = [200, 360, 540, 640, 470, 320, 190]
let firstX = 512 - (CGFloat(heights.count - 1) * spacing + barWidth) / 2
for (index, height) in heights.enumerated() {
    let rect = NSRect(x: firstX + CGFloat(index) * spacing, y: 512 - height / 2, width: barWidth, height: height)
    NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
