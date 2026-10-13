// Generates Resources/AppIcon.icns.   Usage: swift Tools/make-icon.swift
import AppKit

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let s = CGFloat(pixels)
    let body = NSRect(x: s * 0.09375, y: s * 0.09375, width: s * 0.8125, height: s * 0.8125)

    // Icon body with soft drop shadow
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: body.width * 0.2237, yRadius: body.width * 0.2237)
    NSColor.white.setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gradient = NSGradient(starting: NSColor(calibratedRed: 0.31, green: 0.27, blue: 0.90, alpha: 1),
                              ending: NSColor(calibratedRed: 0.02, green: 0.71, blue: 0.83, alpha: 1))!
    gradient.draw(in: bodyPath, angle: -45)

    // Sheet of paper
    let paperW = body.width * 0.50, paperH = body.width * 0.60
    let paper = NSRect(x: body.midX - paperW / 2, y: body.midY - paperH / 2 - body.width * 0.01,
                       width: paperW, height: paperH)
    let paperShadow = NSShadow()
    paperShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    paperShadow.shadowBlurRadius = s * 0.02
    paperShadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    NSGraphicsContext.saveGraphicsState()
    paperShadow.set()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: paper, xRadius: paperW * 0.1, yRadius: paperW * 0.1).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Plain, uniform text lines (what is left after cleaning)
    let lineColor = NSColor(calibratedWhite: 0.78, alpha: 1)
    let lineH = paperH * 0.07
    let left = paper.minX + paperW * 0.14
    let fullW = paperW * 0.72
    let widths: [CGFloat] = [1.0, 1.0, 1.0, 0.55]
    for (i, w) in widths.enumerated() {
        let y = paper.maxY - paperH * 0.27 - CGFloat(i) * paperH * 0.15
        let r = NSRect(x: left, y: y, width: fullW * w, height: lineH)
        lineColor.setFill()
        NSBezierPath(roundedRect: r, xRadius: lineH / 2, yRadius: lineH / 2).fill()
    }
    // Heading line in the accent colour
    let head = NSRect(x: left, y: paper.maxY - paperH * 0.14, width: fullW * 0.5, height: lineH * 1.35)
    NSColor(calibratedRed: 0.31, green: 0.27, blue: 0.90, alpha: 1).setFill()
    NSBezierPath(roundedRect: head, xRadius: lineH * 0.67, yRadius: lineH * 0.67).fill()

    // Sparkle: "clean"
    func sparkle(center: NSPoint, radius r: CGFloat, color: NSColor) {
        let p = NSBezierPath()
        let k: CGFloat = 0.18
        p.move(to: NSPoint(x: center.x, y: center.y + r))
        p.curve(to: NSPoint(x: center.x + r, y: center.y),
                controlPoint1: NSPoint(x: center.x + r * k, y: center.y + r * k),
                controlPoint2: NSPoint(x: center.x + r * k, y: center.y + r * k))
        p.curve(to: NSPoint(x: center.x, y: center.y - r),
                controlPoint1: NSPoint(x: center.x + r * k, y: center.y - r * k),
                controlPoint2: NSPoint(x: center.x + r * k, y: center.y - r * k))
        p.curve(to: NSPoint(x: center.x - r, y: center.y),
                controlPoint1: NSPoint(x: center.x - r * k, y: center.y - r * k),
                controlPoint2: NSPoint(x: center.x - r * k, y: center.y - r * k))
        p.curve(to: NSPoint(x: center.x, y: center.y + r),
                controlPoint1: NSPoint(x: center.x - r * k, y: center.y + r * k),
                controlPoint2: NSPoint(x: center.x - r * k, y: center.y + r * k))
        color.setFill()
        p.fill()
    }
    sparkle(center: NSPoint(x: paper.maxX + paperW * 0.10, y: paper.maxY + paperH * 0.03),
            radius: body.width * 0.15,
            color: NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.29, alpha: 1))
    sparkle(center: NSPoint(x: paper.minX - paperW * 0.06, y: paper.minY + paperH * 0.10),
            radius: body.width * 0.07, color: NSColor.white.withAlphaComponent(0.9))

    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(pixels: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(pixels: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
// Also leave a 1024px preview next to it for the README / GitHub social image.
try render(pixels: 1024).write(to: root.appendingPathComponent("Resources/icon-1024.png"))
