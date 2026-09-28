import AppKit

/// Colors for the window chrome Ghostty draws itself: panels, their headers, rails and
/// overlays. This is the sage palette the default Sage themes go with. Every color resolves
/// against the appearance it is drawn in, so the light values apply in light mode (including
/// `window-theme = light`); the light palette only redefines these primitives.
///
/// The accent isn't here because it depends on `macos-accent-color` and on whether the window
/// is key; see ``ChromeAccent``.
enum ChromePalette {
    // MARK: Surfaces

    /// The window canvas behind the panels and the tab bar.
    static let canvas = dynamic(dark: 0x111713, light: 0xE9ECE5)

    /// Surfaces that sit on the canvas but aren't panels, such as rails and bars.
    static let surface = dynamic(dark: 0x1C2420, light: 0xF5F7F2)

    /// Panel bodies. The same color as the Sage theme backgrounds, so a terminal and a
    /// panel next to it read as the same material.
    static let panel = dynamic(dark: 0x181F1B, light: 0xFCFDFA)

    /// The header band at the top of a panel.
    static let panelHeader = dynamic(dark: 0x1C2420, light: 0xF5F7F2)

    /// Menus, popovers and other floating surfaces.
    static let popover = dynamic(dark: 0x262F29, light: 0xFFFFFF)

    /// Controls raised above a panel, such as key caps and segmented controls.
    static let raised = dynamic(dark: 0x242D27, light: 0xEDF0EA)

    // MARK: Text

    static let text = dynamic(dark: 0xE3E9E1, light: 0x1F2722)
    static let secondaryText = dynamic(dark: 0xA4B1A5, light: 0x56625A)
    static let tertiaryText = dynamic(dark: 0x7E8C82, light: 0x606B62)

    // MARK: Lines and Overlays

    static let separator = dynamic(dark: 0x2B362E, light: 0xDBE0D6)
    static let strongSeparator = dynamic(dark: 0x38443B, light: 0xC7CEC2)

    /// Hovered rows and buttons.
    static let hoverOverlay = dynamic(
        dark: rgb(0xE3E9E1, alpha: 0.06),
        light: rgb(0x1F2722, alpha: 0.055))

    /// Selected rows that aren't drawn with the accent.
    static let selectionOverlay = dynamic(
        dark: rgb(0xE3E9E1, alpha: 0.11),
        light: rgb(0x1F2722, alpha: 0.1))

    /// A frosted fill for tracks laid over the canvas.
    static let glass = dynamic(
        dark: rgb(0xFFFFFF, alpha: 0.06),
        light: rgb(0xFFFFFF, alpha: 0.5))

    /// The raised pill that marks the selection in a track, such as the selected tab.
    static let thumb = dynamic(dark: 0x2C3530, light: 0xFFFFFF)

    /// The highlight along the top edge of raised surfaces.
    static let rim = dynamic(
        dark: rgb(0xFFFFFF, alpha: 0.09),
        light: rgb(0xFFFFFF, alpha: 0.75))

    // MARK: Status

    static let error = dynamic(dark: 0xE08C85, light: 0xB4453C)
    static let warning = dynamic(dark: 0xE0BD72, light: 0xA8781D)
    static let success = dynamic(dark: 0x8FBF78, light: 0x3F7A4D)

    // MARK: Sage Accent

    static let sageAccent = dynamic(dark: 0x9CC487, light: 0x2F6343)
    static let sageAccentHover = dynamic(dark: 0xB0D49C, light: 0x3F7655)

    /// A muted fill of the accent, for selected items drawn on a panel.
    static let sageAccentDeep = dynamic(dark: 0x34432F, light: 0xE3EBDF)

    /// Text and icons drawn on top of a solid accent fill.
    static let onSageAccent = dynamic(dark: 0x172414, light: 0xF2F7EF)

    // MARK: View Kinds

    /// The kinds of panel the chrome distinguishes. Each has its own accent for its frame and
    /// its tool rail button; the terminal uses the chrome accent itself.
    enum ViewKind {
        case terminal
        case files
        case git
        case ai
    }

    static let filesAccent = dynamic(dark: 0xD6A85F, light: 0x9C6B2F)
    static let gitAccent = dynamic(dark: 0xE3906F, light: 0xB0583A)
    static let aiAccent = dynamic(dark: 0xB3A0E6, light: 0x6F5FA6)

    /// The colors of the lanes in the Git view's commit graph, taken from the Sage terminal
    /// palette so the graph matches the terminals next to it.
    static let graphLanes: [NSColor] = [
        dynamic(dark: 0x9CC487, light: 0x2F6343),
        dynamic(dark: 0x85AACB, light: 0x3F6F93),
        dynamic(dark: 0xD6A85F, light: 0x9C6B2F),
        dynamic(dark: 0xCC72CA, light: 0x7C4F95),
        dynamic(dark: 0x74A7CB, light: 0x2F7D74),
        dynamic(dark: 0xE3906F, light: 0xB0583A),
        dynamic(dark: 0xCBCA9B, light: 0x8A6A12),
        dynamic(dark: 0xB3A0E6, light: 0x6F5FA6),
    ]

    /// The fixed accent of a view kind, or nil for kinds that use the chrome accent.
    static func kindAccent(_ kind: ViewKind) -> NSColor? {
        switch kind {
        case .terminal: return nil
        case .files: return filesAccent
        case .git: return gitAccent
        case .ai: return aiAccent
        }
    }
}

// MARK: Shades of a Terminal Background

extension ChromePalette {
    /// The window canvas around terminal cards (`macos-split-frame`): the Sage canvas behind the
    /// Sage themes and a shade darker than the background behind any other theme, so the cards
    /// stand out from it. The background's alpha is kept.
    static func canvas(behind background: NSColor) -> NSColor {
        shade(
            of: background,
            sage: (dark: 0x111713, light: 0xE9ECE5),
            dark: (fraction: 0.28, target: .black),
            light: (fraction: 0.075, target: .black))
    }

    /// The header band of a terminal card: the Sage panel header on the Sage themes and a shade
    /// lifted off the background on any other theme. The background's alpha is kept.
    static func header(over background: NSColor) -> NSColor {
        shade(
            of: background,
            sage: (dark: 0x1C2420, light: 0xF5F7F2),
            dark: (fraction: 0.025, target: .white),
            light: (fraction: 0.03, target: .black))
    }

    private static func shade(
        of background: NSColor,
        sage: (dark: UInt32, light: UInt32),
        dark: (fraction: CGFloat, target: NSColor),
        light: (fraction: CGFloat, target: NSColor)
    ) -> NSColor {
        guard let color = background.usingColorSpace(.sRGB) else { return background }
        let alpha = color.alphaComponent

        // The Sage themes get Wave's exact values rather than an approximation.
        switch hex(of: color) {
        case 0x181F1B: return rgb(sage.dark, alpha: alpha)
        case 0xFCFDFA: return rgb(sage.light, alpha: alpha)
        default: break
        }

        let (fraction, target) = color.isLightColor ? light : dark
        let opaque = color.withAlphaComponent(1)
        let shaded = target.usingColorSpace(.sRGB).flatMap { opaque.blended(withFraction: fraction, of: $0) }
        return (shaded ?? opaque).withAlphaComponent(alpha)
    }

    private static func hex(of color: NSColor) -> UInt32 {
        func component(_ value: CGFloat) -> UInt32 {
            UInt32((min(max(value, 0), 1) * 255).rounded())
        }
        return component(color.redComponent) << 16 |
            component(color.greenComponent) << 8 |
            component(color.blueComponent)
    }
}

// MARK: Helpers

extension ChromePalette {
    /// A color that resolves to `dark` or `light` for the appearance it is drawn in.
    static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.isDark ? dark : light
        }
    }

    private static func dynamic(dark: UInt32, light: UInt32) -> NSColor {
        dynamic(dark: rgb(dark), light: rgb(light))
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
    }
}
