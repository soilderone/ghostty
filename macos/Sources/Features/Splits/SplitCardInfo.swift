import Combine
import SwiftUI

/// What a split's card and header draw of the terminal inside them.
///
/// They used to observe the terminal itself, and a terminal publishes a lot that they don't
/// draw: where the mouse is, whether the cursor is hidden while typing, its size on every frame
/// of a window resize. Each of those redid the views of the card and the header. This publishes
/// only when one of the few things they show changes.
final class SplitCardInfo: ObservableObject {
    struct Value: Equatable {
        var title: String

        /// The terminal's directory, when its shell reported one.
        var directory: String?

        var sshConnection: SSHConnection?

        /// Whether the terminal's process has ended.
        var isDisconnected: Bool

        var badge: TerminalBadge?

        /// The terminal's background, which the card continues into its margin.
        var background: Color
        var backgroundOpacity: Double
    }

    @Published private(set) var value: Value

    private var cancellable: AnyCancellable?

    init(surfaceView: Ghostty.SurfaceView) {
        value = Value(
            title: surfaceView.title,
            directory: Self.directory(surfaceView.pwd),
            sshConnection: surfaceView.sshConnection,
            isDisconnected: surfaceView.childExitedMessage != nil,
            badge: surfaceView.badge,
            background: surfaceView.backgroundColor ?? surfaceView.derivedConfig.backgroundColor,
            backgroundOpacity: surfaceView.derivedConfig.backgroundOpacity)

        // The published values arrive as the new value is about to be stored, so they are used
        // as they come instead of being read back from the terminal.
        let identity = surfaceView.$title.combineLatest(
            surfaceView.$pwd,
            surfaceView.$sshConnection,
            surfaceView.$childExitedMessage)
        let look = surfaceView.$badge.combineLatest(
            surfaceView.$backgroundColor,
            surfaceView.$derivedConfig)
        cancellable = identity.combineLatest(look)
            .map { identity, look in
                Value(
                    title: identity.0,
                    directory: Self.directory(identity.1),
                    sshConnection: identity.2,
                    isDisconnected: identity.3 != nil,
                    badge: look.0,
                    background: look.1 ?? look.2.backgroundColor,
                    backgroundOpacity: look.2.backgroundOpacity)
            }
            .removeDuplicates()
            .sink { [weak self] new in
                guard let self, self.value != new else { return }
                self.value = new
            }
    }

    private static func directory(_ pwd: String?) -> String? {
        guard let pwd, !pwd.isEmpty else { return nil }
        return pwd
    }
}
