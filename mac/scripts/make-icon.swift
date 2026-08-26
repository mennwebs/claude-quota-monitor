#!/usr/bin/env swift
// Draws the app icon: the same four bars the menu bar shows, on a rounded tile.
// Run from the repo root; writes dist/AppIcon.icns via iconutil.
import AppKit
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let out = URL(fileURLWithPath: "dist/AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data? {
    let s = CGFloat(px)
    let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        let inset = s * 0.06
        let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        NSColor(srgbRed: 0.16, green: 0.15, blue: 0.15, alpha: 1).setFill()
        NSBezierPath(roundedRect: tile, xRadius: s * 0.22, yRadius: s * 0.22).fill()

        // Four bars at the heights of a plausible reading, most-used on the right.
        let pcts: [CGFloat] = [0.35, 0.55, 0.92, 0.20]
        let colors = [NSColor.systemGreen, NSColor.systemYellow, NSColor.systemRed, NSColor.systemGreen]
        let area = tile.insetBy(dx: s * 0.17, dy: s * 0.17)
        let gap = area.width * 0.10
        let barW = (area.width - gap * CGFloat(pcts.count - 1)) / CGFloat(pcts.count)

        for (i, pct) in pcts.enumerated() {
            let x = area.minX + CGFloat(i) * (barW + gap)
            let track = NSRect(x: x, y: area.minY, width: barW, height: area.height)
            NSColor.white.withAlphaComponent(0.13).setFill()
            NSBezierPath(roundedRect: track, xRadius: barW / 2, yRadius: barW / 2).fill()

            let fill = NSRect(x: x, y: area.minY, width: barW, height: area.height * pct)
            colors[i].setFill()
            NSBezierPath(roundedRect: fill, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
        return true
    }
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    rep.size = NSSize(width: px, height: px)
    return rep.representation(using: .png, properties: [:])
}

for px in sizes {
    guard let data = draw(px) else { continue }
    try data.write(to: out.appendingPathComponent("icon_\(px)x\(px).png"))
    if px <= 512, let retina = draw(px * 2) {
        try retina.write(to: out.appendingPathComponent("icon_\(px)x\(px)@2x.png"))
    }
}
print("iconset written to \(out.path)")
