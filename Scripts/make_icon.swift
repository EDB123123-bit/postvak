// Draws the app icon. Usage: swift Scripts/make_icon.swift <output.iconset folder>
import AppKit

let out = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px), m = s * 0.09
    let bg = NSBezierPath(roundedRect: NSRect(x: m, y: m, width: s - 2 * m, height: s - 2 * m), xRadius: s * 0.19, yRadius: s * 0.19)
    NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.36, blue: 0.86, alpha: 1), ending: NSColor(calibratedRed: 0.07, green: 0.20, blue: 0.56, alpha: 1))!.draw(in: bg, angle: -90)
    NSColor.white.setFill()
    let w = s * 0.52, h = s * 0.36, x = (s - w) / 2, y = (s - h) / 2
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: s * 0.035, yRadius: s * 0.035).fill()
    let flap = NSBezierPath()
    flap.lineWidth = s * 0.028
    flap.lineCapStyle = .round
    flap.lineJoinStyle = .round
    flap.move(to: NSPoint(x: x + s * 0.025, y: y + h - s * 0.03))
    flap.line(to: NSPoint(x: s / 2, y: y + h * 0.42))
    flap.line(to: NSPoint(x: x + w - s * 0.025, y: y + h - s * 0.03))
    NSColor(calibratedRed: 0.10, green: 0.28, blue: 0.70, alpha: 1).setStroke()
    flap.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try draw(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
