#!/usr/bin/env swift
// Generates AppIcon.icns: a squircle in a gradient picked from the app's name,
// with its initial in white. A placeholder — replace the drawing in makePNG
// with the app's real mark.
// Usage: swift make-icon.swift  (run from the repo root)

import AppKit
import Foundation

let name = "Shipyard"
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

// A stable hue per name, so every placeholder looks different.
let hue = CGFloat(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360

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

    let rect = NSRect(x: 0, y: 0, width: pf, height: pf)
    NSBezierPath(roundedRect: rect, xRadius: pf * 0.225, yRadius: pf * 0.225).addClip()
    NSGradient(colors: [
        NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1),
        NSColor(hue: hue, saturation: 0.75, brightness: 0.40, alpha: 1),
    ])!.draw(in: rect, angle: -90)

    let letter = String(name.prefix(1)) as NSString
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: pf * 0.56, weight: .bold),
        .foregroundColor: NSColor.white,
    ]
    let size = letter.size(withAttributes: attrs)
    letter.draw(at: NSPoint(x: (pf - size.width) / 2, y: (pf - size.height) / 2), withAttributes: attrs)

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
