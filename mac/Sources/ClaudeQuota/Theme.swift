import SwiftUI
import AppKit

/// The panel's own palette, taken from Claude's, and forced dark whatever the Mac is
/// set to. A translucent light popover picks up whatever wallpaper sits behind it, and
/// bars stop reading as bars; an opaque near-black surface keeps the colour meaning.
enum Theme {

    // MARK: - Surfaces

    static let surface  = hex(0x171614)          // the panel
    static let card     = hex(0x232220)          // one account
    static let track    = Color.white.opacity(0.10)
    static let chip     = Color.white.opacity(0.08)

    // MARK: - Text

    static let ink      = hex(0xF5F4EF)
    static let inkMuted = hex(0xA5A29B)
    static let inkFaint = hex(0x77746D)

    /// Claude's terracotta — and the step of the quota ramp where a bar starts asking
    /// for attention, which is why the ramp below reads as one warm family.
    static let brand   = hex(0xD97757)
    static let warning = hex(0xE3B341)

    // MARK: - Quota ramp

    /// Thresholds match the ones already in use in this machine's `statusline.sh`
    /// (50 / 80), plus a final band at 95 for "about to stop working".
    static func color(for pct: Double) -> Color {
        switch pct {
        case ..<50:  return hex(0x7FA98A)   // sage
        case ..<80:  return warning         // gold
        case ..<95:  return brand           // terracotta
        default:     return hex(0xD2453B)   // clay red
        }
    }

    /// The menu bar glyph keeps system colours. It is drawn on the *system's* menu bar,
    /// whose appearance the app does not control, and these are the colours that adapt
    /// to it — a fixed dark-mode ramp would wash out on a light menu bar.
    static func nsColor(for pct: Double) -> NSColor {
        switch pct {
        case ..<50:  return .systemGreen
        case ..<80:  return .systemYellow
        case ..<95:  return .systemOrange
        default:     return .systemRed
        }
    }

    // MARK: - Metrics

    static let barHeight: CGFloat = 7

    /// One account. Everything in a row — label, bar, percentage, countdown — is
    /// budgeted against this, so it is the number to change when the panel feels
    /// cramped, not the panel width.
    static let cardWidth: CGFloat = 250
    static let cardGap: CGFloat = 6
    static let panelPadding: CGFloat = 8

    /// Accounts sit side by side, so the panel is only as wide as the columns it shows.
    static func panelWidth(columns: Int) -> CGFloat {
        panelPadding * 2 + CGFloat(columns) * cardWidth + CGFloat(max(0, columns - 1)) * cardGap
    }

    private static func hex(_ v: UInt32) -> Color {
        Color(.sRGB,
              red: Double((v >> 16) & 0xFF) / 255,
              green: Double((v >> 8) & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255)
    }
}
