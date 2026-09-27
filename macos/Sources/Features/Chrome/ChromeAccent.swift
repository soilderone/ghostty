import AppKit
import SwiftUI

/// The accent color of the chrome Ghostty draws itself. It follows `macos-accent-color`, the
/// system accent color when that is `system`, and turns gray while a window isn't key, as
/// AppKit does for its own controls.
///
/// SwiftUI views observe ``shared`` so they redraw when the setting or the system accent
/// changes, and read `controlActiveState` from the environment to know if their window is key.
final class ChromeAccent: ObservableObject {
    static let shared = ChromeAccent()

    @Published private(set) var setting: Ghostty.Config.MacOSAccentColor = .sage

    /// Incremented when the system accent color changes. `NSColor.controlAccentColor` is
    /// dynamic, but anything that already resolved it only picks up the new color on a redraw.
    @Published private(set) var systemAccentRevision: Int = 0

    private var observers: [NSObjectProtocol] = []

    private init() {
        // The first is the documented notification. The distributed one is what System
        // Settings posts when the accent changes; a redundant redraw costs nothing.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.systemAccentRevision += 1
        })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleColorPreferencesChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.systemAccentRevision += 1
        })
    }

    /// Applies `macos-accent-color` from the app configuration.
    func update(from config: Ghostty.Config) {
        let setting = config.macosAccentColor
        guard setting != self.setting else { return }
        self.setting = setting
    }

    /// The chrome accent for a window, gray unless that window is key.
    func nsColor(inKeyWindow isKey: Bool) -> NSColor {
        guard isKey else { return ChromePalette.tertiaryText }
        switch setting {
        case .sage: return ChromePalette.sageAccent
        case .system: return .controlAccentColor
        }
    }

    /// The accent for a kind of view: the chrome accent for terminals and the kind's own
    /// color for the others. All of them turn gray while the window isn't key.
    func nsColor(for kind: ChromePalette.ViewKind, inKeyWindow isKey: Bool) -> NSColor {
        guard isKey else { return ChromePalette.tertiaryText }
        return ChromePalette.kindAccent(kind) ?? nsColor(inKeyWindow: true)
    }

    func color(inKeyWindow isKey: Bool) -> Color {
        Color(nsColor: nsColor(inKeyWindow: isKey))
    }

    func color(for kind: ChromePalette.ViewKind, inKeyWindow isKey: Bool) -> Color {
        Color(nsColor: nsColor(for: kind, inKeyWindow: isKey))
    }
}
