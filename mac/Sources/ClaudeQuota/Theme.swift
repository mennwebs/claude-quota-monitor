import SwiftUI
import AppKit

/// Thresholds match the ones already in use in this machine's `statusline.sh`
/// (50 / 80), plus a final band at 95 for "about to stop working".
enum Theme {
    static func color(for pct: Double) -> Color {
        switch pct {
        case ..<50:  return .green
        case ..<80:  return .yellow
        case ..<95:  return .orange
        default:     return .red
        }
    }

    static func nsColor(for pct: Double) -> NSColor {
        switch pct {
        case ..<50:  return .systemGreen
        case ..<80:  return .systemYellow
        case ..<95:  return .systemOrange
        default:     return .systemRed
        }
    }

    static let barHeight: CGFloat = 7
    static let panelWidth: CGFloat = 360
}
