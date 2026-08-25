import AppKit

/// The menu bar glyph: one vertical bar per account, drawn in a stable order.
///
/// The whole point of the item is to answer "which account is nearly full" without
/// opening anything, so each bar shows that account's *binding* limit — the ceiling
/// closest to blocking it — not just the 5-hour window.
enum MenuBarIcon {

    struct Bar {
        var pct: Double
        var color: NSColor
        /// Past the freshness cut-off the number is not trustworthy enough to colour.
        var grayed: Bool
        /// The window's reset time has passed and no reading has confirmed it yet.
        var awaitingReset: Bool
    }

    static func render(_ bars: [Bar]) -> NSImage {
        let count = max(bars.count, 1)
        let barW: CGFloat = 3.5
        let gap: CGFloat = 2.5
        let height: CGFloat = 15
        let width = CGFloat(count) * barW + CGFloat(count - 1) * gap

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            guard !bars.isEmpty else {
                // No account has ever reported. An empty outline reads as "nothing yet",
                // which is the truth, rather than a zeroed bar that reads as "0% used".
                let r = NSRect(x: 0, y: 0, width: barW, height: height)
                NSColor.tertiaryLabelColor.setStroke()
                let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 1.5, yRadius: 1.5)
                p.lineWidth = 1
                p.stroke()
                return true
            }

            for (i, bar) in bars.enumerated() {
                let x = CGFloat(i) * (barW + gap)
                let track = NSRect(x: x, y: 0, width: barW, height: height)

                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(roundedRect: track, xRadius: barW / 2, yRadius: barW / 2).fill()

                if bar.awaitingReset {
                    NSColor.tertiaryLabelColor.setStroke()
                    let p = NSBezierPath(roundedRect: track.insetBy(dx: 0.5, dy: 0.5),
                                         xRadius: barW / 2, yRadius: barW / 2)
                    p.lineWidth = 1
                    p.setLineDash([2, 2], count: 2, phase: 0)
                    p.stroke()
                    continue
                }

                let filled = max(1.5, height * CGFloat(min(100, max(0, bar.pct)) / 100))
                let fill = NSRect(x: x, y: 0, width: barW, height: filled)
                (bar.grayed ? NSColor.secondaryLabelColor.withAlphaComponent(0.55) : bar.color).setFill()
                NSBezierPath(roundedRect: fill, xRadius: barW / 2, yRadius: barW / 2).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
