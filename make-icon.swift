#!/usr/bin/env swift
// Generates AppIcon.icns: a slate-to-navy squircle, a gold crane lowering an
// app onto a white hull — every app loaded and shipped from one yard.
// Usage: swift make-icon.swift  (run from the repo root)

import AppKit
import Foundation

let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = here.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func makePNG(size px: Int) -> Data? {
    let pf = CGFloat(px)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)
    else { return nil }
    rep.size = NSSize(width: pf, height: pf)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = ctx

    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: pf * x, y: pf * y) }

    let rect = NSRect(x: 0, y: 0, width: pf, height: pf)
    NSBezierPath(roundedRect: rect, xRadius: pf * 0.225, yRadius: pf * 0.225).addClip()
    NSGradient(colors: [
        NSColor(srgbRed: 0.24, green: 0.42, blue: 0.64, alpha: 1),
        NSColor(srgbRed: 0.06, green: 0.12, blue: 0.26, alpha: 1),
    ])!.draw(in: rect, angle: -90)

    // Crane: mast and jib, then the cable down to the load.
    let gold = NSColor(srgbRed: 0.96, green: 0.71, blue: 0.27, alpha: 1)
    gold.setStroke()
    let crane = NSBezierPath()
    crane.move(to: p(0.30, 0.30))
    crane.line(to: p(0.30, 0.82))
    crane.line(to: p(0.80, 0.82))
    crane.lineWidth = max(1.5, pf * 0.055)
    crane.lineCapStyle = .round
    crane.lineJoinStyle = .round
    crane.stroke()
    let cable = NSBezierPath()
    cable.move(to: p(0.66, 0.82))
    cable.line(to: p(0.66, 0.62))
    cable.lineWidth = max(1, pf * 0.022)
    cable.stroke()

    // The load: an app, squircle and all.
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(origin: p(0.56, 0.42), size: NSSize(width: pf * 0.20, height: pf * 0.20)),
                 xRadius: pf * 0.05, yRadius: pf * 0.05).fill()

    // The hull it's going into.
    let hull = NSBezierPath()
    hull.move(to: p(0.12, 0.36))
    hull.line(to: p(0.88, 0.36))
    hull.line(to: p(0.74, 0.15))
    hull.line(to: p(0.26, 0.15))
    hull.close()
    NSColor(calibratedWhite: 1, alpha: 0.92).setFill()
    hull.fill()

    return rep.representation(using: .png, properties: [:])
}

for (file, px) in sizes {
    guard let data = makePNG(size: px) else { continue }
    try data.write(to: iconset.appendingPathComponent("\(file).png"))
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path, "-o", here.appendingPathComponent("AppIcon.icns").path]
try proc.run()
proc.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Wrote AppIcon.icns")
