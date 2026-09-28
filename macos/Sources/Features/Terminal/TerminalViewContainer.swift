import AppKit
import SwiftUI

/// Use this container to achieve a glass effect at the window level.
/// Modifying `NSThemeFrame` can sometimes be unpredictable.
class TerminalViewContainer: NSView {
    private let terminalView: NSView

    /// Background color applied with glass effect
    private(set) var glassEffectView: NSView?
    private var derivedConfig: DerivedConfig?

    /// The `macos-window-vibrancy` material behind the terminals. It is only visible
    /// where the window frame is left clear, since the terminals are opaque.
    private var vibrancyView: TerminalVibrancyView?

    /// Set by the window when `macos-window-vibrancy` is in effect.
    var showsVibrancy: Bool = false {
        didSet {
            guard showsVibrancy != oldValue else { return }
            updateVibrancyView()
        }
    }

    /// Pins the terminal view's leading and trailing edges to ours, until sidebars take over.
    private var terminalHorizontalConstraints: [NSLayoutConstraint] = []

    /// The window's sidebars, for windows that have them.
    private var sidebarsLayout: TerminalSidebarsLayout?

    var windowThemeFrameView: NSView? {
        window?.contentView?.superview
    }

    var windowCornerRadius: CGFloat? {
        guard let window, window.responds(to: Selector(("_cornerRadius"))) else {
            return nil
        }

        return window.value(forKey: "_cornerRadius") as? CGFloat
    }

    init<Root: View>(@ViewBuilder rootView: () -> Root) {
        self.terminalView = NSHostingView(rootView: rootView())
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The initial content size to use as a fallback before the SwiftUI
    /// view hierarchy has completed layout (i.e. before @FocusedValue
    /// propagates `lastFocusedSurface`). Once the hosting view reports
    /// a valid intrinsic size, this fallback is no longer used.
    var initialContentSize: NSSize?

    override var intrinsicContentSize: NSSize {
        var size = terminalView.intrinsicContentSize
        // The hosting view returns a valid size once SwiftUI has laid out
        // with the correct idealWidth/idealHeight. Before that (when
        // @FocusedValue hasn't propagated), it returns a tiny default.
        // Fall back to initialContentSize in that case.
        if let initialContentSize,
           size.width < initialContentSize.width || size.height < initialContentSize.height {
            size = initialContentSize
        }

        // `window-width` counts terminal columns, so the sidebars' width adds to it.
        if let sidebarsLayout, size.width > 0 {
            size.width += sidebarsLayout.widthBesideTerminal
        }
        return size
    }

    private func setup() {
        addSubview(terminalView)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalHorizontalConstraints = [
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ]
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ] + terminalHorizontalConstraints)
    }

    /// Lays out the window's sidebars beside the terminal. Call this once, before the
    /// container is added to its window.
    ///
    /// - Parameters:
    ///   - extendsIntoTitlebar: Whether the terminal extends into the titlebar area (the
    ///     hidden titlebar style).
    ///   - returnFocus: Called when a sidebar closes while it has keyboard focus.
    func installSidebars(
        _ sidebars: TerminalSidebars,
        extendsIntoTitlebar: Bool,
        returnFocus: @escaping () -> Void
    ) {
        guard sidebarsLayout == nil else { return }
        NSLayoutConstraint.deactivate(terminalHorizontalConstraints)
        sidebarsLayout = TerminalSidebarsLayout(
            container: self,
            terminalView: terminalView,
            sidebars: sidebars,
            extendsIntoTitlebar: extendsIntoTitlebar,
            returnFocus: returnFocus)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateGlassEffectIfNeeded()
        updateGlassEffectTopInsetIfNeeded()
        updateVibrancyView()
    }

    override func layout() {
        super.layout()
        updateGlassEffectTopInsetIfNeeded()
        updateVibrancyTopInset()
    }

    func ghosttyConfigDidChange(_ config: Ghostty.Config, preferredBackgroundColor: NSColor?) {
        let newValue = DerivedConfig(config: config, preferredBackgroundColor: preferredBackgroundColor, cornerRadius: windowCornerRadius)
        guard newValue != derivedConfig else { return }
        derivedConfig = newValue

        // Attach the glass effect synchronously if missing to prevent flicker when a new tab appears.
        // Existing updates remain deferred, as they can occur during SwiftUI rendering.
        if glassEffectView == nil {
            updateGlassEffectIfNeeded()
        } else {
            DispatchQueue.main.async(execute: updateGlassEffectIfNeeded)
        }
    }
}

// MARK: Vibrancy

/// The material behind the window frame for `macos-window-vibrancy`.
private class TerminalVibrancyView: NSVisualEffectView {
    private(set) var topConstraint: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .followsWindowActiveState
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func pin(to container: NSView, topOffset: CGFloat) {
        let top = topAnchor.constraint(equalTo: container.topAnchor, constant: topOffset)
        NSLayoutConstraint.activate([
            top,
            leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bottomAnchor.constraint(equalTo: container.bottomAnchor),
            trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        topConstraint = top
    }

    // Purely a backdrop: the titlebar and terminals above it handle all input.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension TerminalViewContainer {
    private func updateVibrancyView() {
        guard showsVibrancy, let themeFrameView = windowThemeFrameView else {
            vibrancyView?.removeFromSuperview()
            vibrancyView = nil
            return
        }
        guard vibrancyView == nil else { return }

        // The content view starts below the titlebar, so extend upward by the
        // titlebar's height to sit behind it too (the same as the glass view).
        let view = TerminalVibrancyView()
        addSubview(view, positioned: .below, relativeTo: nil)
        view.pin(to: self, topOffset: -themeFrameView.safeAreaInsets.top)
        vibrancyView = view
    }

    private func updateVibrancyTopInset() {
        guard let vibrancyView, let themeFrameView = windowThemeFrameView else { return }
        let offset = -themeFrameView.safeAreaInsets.top
        guard vibrancyView.topConstraint?.constant != offset else { return }
        vibrancyView.topConstraint?.constant = offset
    }
}

// MARK: - BaseTerminalController + terminalViewContainer

extension BaseTerminalController {
    var terminalViewContainer: TerminalViewContainer? {
        window?.contentView as? TerminalViewContainer
    }
}

// MARK: Glass

/// An `NSView` that contains a liquid glass background effect and
/// an inactive-window tint overlay.
#if compiler(>=6.2)
@available(macOS 26.0, *)
private class TerminalGlassView: NSView, ObservableObject {
    /// We use this to apply glass effect to background colors
    ///
    struct GlassBackground: View {
        @ObservedObject var model: GlassViewModel

        var body: some View {
            model.color
                .glassEffect(
                    model.glass,
                    in: RoundedRectangle(cornerRadius: model.cornerRadius)
                )
        }
    }

    class GlassViewModel: ObservableObject {
        @Published var backgroundColor: Color = .clear
        @Published var backgroundOpacity: Double = 0
        @Published var cornerRadius: CGFloat = 0
        @Published var glass: Glass = .identity

        /// backgroundColor applied with backgroundOpacity
        var color: Color {
            backgroundColor.opacity(backgroundOpacity)
        }
    }

    private let glassEffectView: NSView
    private var topConstraint: NSLayoutConstraint!
    private let glassViewModel: GlassViewModel

    init(topOffset: CGFloat) {
        let viewModel = GlassViewModel()
        self.glassEffectView = NSHostingView(rootView: GlassBackground(model: viewModel))
        self.glassViewModel = viewModel
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false

        // Glass effect view fills this view.
        glassEffectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassEffectView)
        topConstraint = glassEffectView.topAnchor.constraint(
            equalTo: topAnchor,
            constant: topOffset
        )
        NSLayoutConstraint.activate([
            topConstraint,
            glassEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            glassEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Configures the glass, tint color, corner radius.
    func configure(
        glass: Glass,
        backgroundColor: NSColor,
        backgroundOpacity: Double,
        cornerRadius: CGFloat?,
    ) {
        glassViewModel.backgroundColor = Color(backgroundColor)
        glassViewModel.backgroundOpacity = backgroundOpacity
        glassViewModel.cornerRadius = cornerRadius ?? 0
        glassViewModel.glass = glass
    }

    /// Updates the top inset offset for both the glass effect and tint overlay.
    /// Call this when the safe area insets change (e.g., during layout).
    func updateTopInset(_ offset: CGFloat) {
        topConstraint.constant = offset
    }
}
#endif // compiler(>=6.2)

extension TerminalViewContainer {
#if compiler(>=6.2)
    @available(macOS 26.0, *)
    private func addGlassEffectViewIfNeeded() -> TerminalGlassView? {
        if let existed = glassEffectView as? TerminalGlassView {
            updateGlassEffectTopInsetIfNeeded()
            return existed
        }
        guard let themeFrameView = windowThemeFrameView else {
            return nil
        }
        let effectView = TerminalGlassView(topOffset: -themeFrameView.safeAreaInsets.top)
        addSubview(effectView, positioned: .below, relativeTo: terminalView)
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        glassEffectView = effectView
        return effectView
    }
#endif // compiler(>=6.2)

    private func updateGlassEffectIfNeeded() {
#if compiler(>=6.2)
        guard #available(macOS 26.0, *), let derivedConfig else {
            glassEffectView?.removeFromSuperview()
            glassEffectView = nil
            return
        }
        guard let effectView = addGlassEffectViewIfNeeded() else {
            return
        }

        effectView.configure(
            glass: derivedConfig.glass.official,
            backgroundColor: derivedConfig.backgroundColor,
            backgroundOpacity: derivedConfig.backgroundOpacity,
            cornerRadius: derivedConfig.cornerRadius,
        )
#endif // compiler(>=6.2)
    }

    private func updateGlassEffectTopInsetIfNeeded() {
#if compiler(>=6.2)
        guard
            #available(macOS 26.0, *),
            let effectView = glassEffectView as? TerminalGlassView,
            let themeFrameView = windowThemeFrameView
        else {
            return
        }
        effectView.updateTopInset(-themeFrameView.safeAreaInsets.top)
#endif // compiler(>=6.2)
    }

    struct DerivedConfig: Equatable {
        let glass: BackportGlass
        let backgroundColor: NSColor
        let backgroundOpacity: Double
        let cornerRadius: CGFloat?

        init?(config: Ghostty.Config, preferredBackgroundColor: NSColor?, cornerRadius: CGFloat?) {
            switch config.backgroundBlur {
            case .macosGlassRegular:
                glass = .regular
            case .macosGlassClear:
                glass = .clear
            default:
                return nil
            }
            self.backgroundColor = preferredBackgroundColor ?? NSColor(config.backgroundColor)
            self.backgroundOpacity = config.backgroundOpacity
            self.cornerRadius = cornerRadius
        }
    }
}
