import AppKit
import SwiftUI

/// A mark on a terminal for something that happened in it while nobody was looking, so a tab
/// in the background says a command failed or a bell rang. Wave calls these badges. They come
/// from what Ghostty already reports: a command finishing (with shell integration), the bell,
/// and desktop notifications (OSC 9 and OSC 777).
///
/// A terminal only gets a badge while it isn't focused, and loses it when it is. The tab shows
/// the most urgent badge of the terminals in it.
enum TerminalBadge: Int, Comparable {
    /// A command finished without an error.
    case succeeded = 1
    case bell
    case notification
    case failed

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The badge for a command that finished with this exit code, or nil when it needs none.
    /// A code below zero means the shell didn't report one.
    init?(exitCode: Int) {
        switch exitCode {
        case 130:
            // Interrupted with control-C: whoever did that is looking at the terminal.
            return nil
        case 1...:
            self = .failed
        default:
            self = .succeeded
        }
    }

    var symbol: String {
        switch self {
        case .succeeded: return "checkmark.circle.fill"
        case .bell: return "bell.fill"
        case .notification: return "bell.badge.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var title: String {
        switch self {
        case .succeeded: return "A command finished"
        case .bell: return "The bell rang"
        case .notification: return "A notification came in"
        case .failed: return "A command failed"
        }
    }

    var color: NSColor {
        switch self {
        case .succeeded: return ChromePalette.success
        case .bell, .notification: return ChromePalette.warning
        case .failed: return ChromePalette.error
        }
    }
}

extension Sequence where Element == TerminalBadge? {
    /// The most urgent of the badges, for a tab with several terminals.
    var mostUrgent: TerminalBadge? {
        compactMap { $0 }.max()
    }
}

extension Notification.Name {
    /// A terminal's badge changed. The object is the terminal's surface view.
    static let ghosttyBadgeDidChange = Notification.Name("com.mitchellh.ghostty.badgeDidChange")
}

/// A badge as a small icon.
struct TerminalBadgeIcon: View {
    let badge: TerminalBadge
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: badge.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundColor(Color(nsColor: badge.color))
            .help(badge.title)
            .accessibilityLabel(badge.title)
    }
}
