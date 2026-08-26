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
    private var observers: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock tile, no window on launch. `LSUIElement` in Info.plist
        // covers the bundled case; this covers running the binary straight from `.build`.
        NSApp.setActivationPolicy(.accessory)
        observers = [DarkWindows.observe()] + SettingsWindow.observe()
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

/// Bringing the settings window to the front, and keeping it there.
///
/// `SettingsLink` creates the window but hands it no focus, and the same click dismisses
/// the panel, which deactivates a menu-bar-only app and drops the new window behind
/// whatever the user was looking at. From their side that is indistinguishable from a
/// button that does nothing.
///
/// Two things are needed, and neither is enough alone:
///
/// - `.regular` while the window is open. An `.accessory` app does not really win an
///   activation contest; whichever app was frontmost takes focus back as the panel
///   closes and pulls the settings window down with it. `.regular` is what "this app has
///   a window you are using" means to macOS, and brings a Dock tile and menu bar with it.
/// - `.floating` for as long as the window is open, so that an app which re-activates
///   itself a second later cannot cover it. The window is open because it was asked for;
///   it stops floating when it is closed.
///
/// The click itself cannot be hooked — a `simultaneousGesture` on `SettingsLink` never
/// fires — so the window is watched for instead.
enum SettingsWindow {
    private static let identifier = "com_apple_SwiftUI_Settings_window"
    private static var isOpen = false

    static func observe() -> [Any] {
        let appeared = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow,
                  window.identifier?.rawValue == identifier,
                  window.isVisible, !isOpen
            else { return }
            isOpen = true
            NSApp.setActivationPolicy(.regular)
            window.level = .floating
            front(window)
            // The panel is still dismissing itself, and that hands focus back to
            // whoever had it. Take it once more after that has happened.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard isOpen, window.isVisible else { return }
                front(window)
            }
        }

        let closed = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow,
                  window.identifier?.rawValue == identifier else { return }
            isOpen = false
            window.level = .normal
            // Back to a menu bar app: no Dock tile, no menu bar of its own.
            NSApp.setActivationPolicy(.accessory)
        }

        return [appeared, closed]
    }

    private static func front(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
