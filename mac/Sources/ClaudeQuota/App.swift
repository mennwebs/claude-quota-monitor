import SwiftUI
import AppKit

struct ClaudeQuotaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appearanceObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock tile, no window on launch. `LSUIElement` in Info.plist
        // covers the bundled case; this covers running the binary straight from `.build`.
        NSApp.setActivationPolicy(.accessory)
        appearanceObserver = DarkWindows.observe()
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Store.shared.stop() }
    }
}

/// The status item itself: one bar per account plus, optionally, the single number
/// that matters — how full the fullest account is.
struct MenuBarLabel: View {
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: MenuBarIcon.render(bars))
            if store.settings.showPercentInMenuBar, let worst {
                Text("\(Int(worst.rounded()))%")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
        }
        .onAppear { store.start() }
    }

    private var bars: [MenuBarIcon.Bar] {
        store.visibleAccounts.map { account in
            guard let reading = account.binding(at: store.now)?.reading else {
                return MenuBarIcon.Bar(pct: 0, color: .systemGray, grayed: true, awaitingReset: false)
            }
            // The bar's own reading decides whether it is trustworthy. The account may
            // be refreshing another limit constantly while this one goes stale.
            let freshness = reading.freshness(at: store.now, thresholds: store.settings.thresholds)
            let pct = reading.effectivePct(at: store.now)
            return MenuBarIcon.Bar(
                pct: pct,
                color: Theme.nsColor(for: pct),
                grayed: freshness >= .stale,
                awaitingReset: reading.expired(at: store.now)
            )
        }
    }

    /// Only readings we still believe get to drive the headline number — otherwise a
    /// figure from this morning would sit in the menu bar looking current.
    private var worst: Double? {
        store.visibleAccounts
            .compactMap { $0.binding(at: store.now)?.reading }
            .filter { $0.freshness(at: store.now, thresholds: store.settings.thresholds) < .stale }
            .map { $0.effectivePct(at: store.now) }
            .max()
    }
}

/// The panel paints its own near-black surface, but the frame *around* a popover is
/// drawn by AppKit in the system's appearance — a pale grey ring around a dark panel on
/// a light Mac, which `preferredColorScheme` does not reach.
///
/// Only the panel's own window is switched. `NSApp.appearance` would take the menu bar
/// glyph with it, which is drawn in label colours that have to match the *system's*
/// menu bar, and the settings window stays in the Mac's own appearance because it is an
/// ordinary settings window and should look like one.
enum DarkWindows {
    static func observe() -> Any {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow, window.appearance == nil,
                  String(describing: type(of: window)).contains("MenuBarExtraWindow")
            else { return }
            window.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
