import SwiftUI
import Combine

// MARK: - Color Initializer

extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Catalyst Tokens

enum Catalyst {

    // MARK: - Surfaces

    enum Surface {
        private static let bgLight      = Color(hex: 0xFFFFFF)
        private static let bgDark       = Color(hex: 0x1E1E1E)
        private static let surfaceLight = Color(hex: 0xF5F5F5)
        private static let surfaceDark  = Color(hex: 0x2B2B2B)
        private static let raisedLight  = Color(hex: 0xEBEBEB)
        private static let raisedDark   = Color(hex: 0x333536)

        static func bg(_ s: ColorScheme) -> Color      { s == .dark ? bgDark : bgLight }
        static func surface(_ s: ColorScheme) -> Color  { s == .dark ? surfaceDark : surfaceLight }
        static func raised(_ s: ColorScheme) -> Color   { s == .dark ? raisedDark : raisedLight }
        static func overlay(_ s: ColorScheme) -> Color  { s == .dark ? .black.opacity(0.3) : .black.opacity(0.06) }
    }

    // MARK: - Text

    enum Text {
        private static let primaryLight   = Color(hex: 0x2B2B2B)
        private static let primaryDark    = Color(hex: 0xDCDCDC)
        private static let secondaryLight = Color(hex: 0x636363)
        private static let secondaryDark  = Color(hex: 0xA9B7C6)
        private static let tertiaryLight  = Color(hex: 0x999999)
        private static let tertiaryDark   = Color(hex: 0x787878)

        static func primary(_ s: ColorScheme) -> Color   { s == .dark ? primaryDark : primaryLight }
        static func secondary(_ s: ColorScheme) -> Color { s == .dark ? secondaryDark : secondaryLight }
        /// Decorative only — placeholders, disabled hints. Not AA for body text.
        static func tertiary(_ s: ColorScheme) -> Color  { s == .dark ? tertiaryDark : tertiaryLight }
        static let onAccent = Color.white
    }

    // MARK: - Borders

    enum Border {
        private static let primaryLight   = Color(hex: 0xD1D1D1)
        private static let primaryDark    = Color(hex: 0x505355)
        private static let secondaryLight = Color(hex: 0xBEBEBE)
        private static let secondaryDark  = Color(hex: 0x636567)

        static func primary(_ s: ColorScheme) -> Color   { s == .dark ? primaryDark : primaryLight }
        static func secondary(_ s: ColorScheme) -> Color { s == .dark ? secondaryDark : secondaryLight }
    }

    // MARK: - Accent Colors (12-color semantic palette)

    struct AccentColor: Equatable {
        let fillLight: Color, fillDark: Color
        let hoverLight: Color, hoverDark: Color
        let subtleLight: Color, subtleDark: Color
        let textLight: Color, textDark: Color

        func fill(_ s: ColorScheme) -> Color   { s == .dark ? fillDark : fillLight }
        func hover(_ s: ColorScheme) -> Color  { s == .dark ? hoverDark : hoverLight }
        func subtle(_ s: ColorScheme) -> Color { s == .dark ? subtleDark : subtleLight }
        func text(_ s: ColorScheme) -> Color   { s == .dark ? textDark : textLight }
    }

    static let primary = AccentColor(
        fillLight: Color(hex: 0x2E65CC), fillDark: Color(hex: 0x3568C0),
        hoverLight: Color(hex: 0x2758B3), hoverDark: Color(hex: 0x4075CA),
        subtleLight: Color(hex: 0xE5ECF8), subtleDark: Color(hex: 0x1C2840),
        textLight: Color(hex: 0x24508F), textDark: Color(hex: 0x5A95F5)
    )
    static let success = AccentColor(
        fillLight: Color(hex: 0x3C7A47), fillDark: Color(hex: 0x3A8248),
        hoverLight: Color(hex: 0x326A3C), hoverDark: Color(hex: 0x449050),
        subtleLight: Color(hex: 0xEBF4ED), subtleDark: Color(hex: 0x1C2D20),
        textLight: Color(hex: 0x2F6338), textDark: Color(hex: 0x6AAF72)
    )
    static let warning = AccentColor(
        fillLight: Color(hex: 0xD9A74E), fillDark: Color(hex: 0xC9A344),
        hoverLight: Color(hex: 0xC49542), hoverDark: Color(hex: 0xD0AD55),
        subtleLight: Color(hex: 0xFBF0D9), subtleDark: Color(hex: 0x2C2618),
        textLight: Color(hex: 0x654D16), textDark: Color(hex: 0xE8BF6A)
    )
    static let danger = AccentColor(
        fillLight: Color(hex: 0xC94448), fillDark: Color(hex: 0xBD4848),
        hoverLight: Color(hex: 0xB33B3F), hoverDark: Color(hex: 0xC85555),
        subtleLight: Color(hex: 0xFBEAEA), subtleDark: Color(hex: 0x2D1C1C),
        textLight: Color(hex: 0x8C2424), textDark: Color(hex: 0xE07070)
    )
    static let info = AccentColor(
        fillLight: Color(hex: 0x3E6FA3), fillDark: Color(hex: 0x4578A3),
        hoverLight: Color(hex: 0x356192), hoverDark: Color(hex: 0x5085B0),
        subtleLight: Color(hex: 0xE5EDF5), subtleDark: Color(hex: 0x1C2838),
        textLight: Color(hex: 0x335C87), textDark: Color(hex: 0x7EAED4)
    )
    static let purple = AccentColor(
        fillLight: Color(hex: 0x7B5D96), fillDark: Color(hex: 0x7A5D96),
        hoverLight: Color(hex: 0x6B5084), hoverDark: Color(hex: 0x866BA0),
        subtleLight: Color(hex: 0xEFEBF3), subtleDark: Color(hex: 0x282032),
        textLight: Color(hex: 0x583F6E), textDark: Color(hex: 0xAD8FBF)
    )
    static let teal = AccentColor(
        fillLight: Color(hex: 0x2D7373), fillDark: Color(hex: 0x2D7878),
        hoverLight: Color(hex: 0x256464), hoverDark: Color(hex: 0x358585),
        subtleLight: Color(hex: 0xE4EFEF), subtleDark: Color(hex: 0x1C2D2D),
        textLight: Color(hex: 0x245454), textDark: Color(hex: 0x4DA6A6)
    )
    static let orange = AccentColor(
        fillLight: Color(hex: 0xA25B22), fillDark: Color(hex: 0xA8622C),
        hoverLight: Color(hex: 0x8E4F1D), hoverDark: Color(hex: 0xB57038),
        subtleLight: Color(hex: 0xF8EDE2), subtleDark: Color(hex: 0x2D2218),
        textLight: Color(hex: 0x854A1B), textDark: Color(hex: 0xD4894A)
    )
    static let indigo = AccentColor(
        fillLight: Color(hex: 0x4B47A8), fillDark: Color(hex: 0x4B47A8),
        hoverLight: Color(hex: 0x423EA0), hoverDark: Color(hex: 0x5854B2),
        subtleLight: Color(hex: 0xEEEDF8), subtleDark: Color(hex: 0x222040),
        textLight: Color(hex: 0x3A3580), textDark: Color(hex: 0x9A95DA)
    )
    static let rose = AccentColor(
        fillLight: Color(hex: 0xB83658), fillDark: Color(hex: 0xB83658),
        hoverLight: Color(hex: 0xA83050), hoverDark: Color(hex: 0xC44068),
        subtleLight: Color(hex: 0xFBEAEE), subtleDark: Color(hex: 0x2D1C22),
        textLight: Color(hex: 0x8A2440), textDark: Color(hex: 0xE07090)
    )
    static let lime = AccentColor(
        fillLight: Color(hex: 0x4A8018), fillDark: Color(hex: 0x4A8018),
        hoverLight: Color(hex: 0x417215), hoverDark: Color(hex: 0x559222),
        subtleLight: Color(hex: 0xF0F6E4), subtleDark: Color(hex: 0x1E2C14),
        textLight: Color(hex: 0x33580F), textDark: Color(hex: 0x8DC050)
    )
    static let slate = AccentColor(
        fillLight: Color(hex: 0x5A6577), fillDark: Color(hex: 0x5A6577),
        hoverLight: Color(hex: 0x515C6E), hoverDark: Color(hex: 0x657282),
        subtleLight: Color(hex: 0xEEF0F3), subtleDark: Color(hex: 0x1E2228),
        textLight: Color(hex: 0x3E4854), textDark: Color(hex: 0x94A0B0)
    )

    private static let _warningOnAccent = Color(hex: 0x3F300D)
    static func warningOnAccent(_ s: ColorScheme) -> Color { _warningOnAccent }

    static let allAccents: [(name: String, color: AccentColor)] = [
        ("primary", primary), ("success", success), ("warning", warning),
        ("danger", danger), ("info", info), ("purple", purple),
        ("teal", teal), ("orange", orange), ("indigo", indigo),
        ("rose", rose), ("lime", lime), ("slate", slate)
    ]

    // MARK: - Typography (Apple HIG scale)

    enum Typography {
        static let largeTitle: Font  = .system(size: 32, weight: .bold)
        static let title1: Font      = .system(size: 26, weight: .bold)
        static let title2: Font      = .system(size: 21, weight: .semibold)
        static let title3: Font      = .system(size: 19, weight: .semibold)
        static let headline: Font    = .system(size: 16, weight: .semibold)
        static let body: Font        = .system(size: 16, weight: .regular)
        static let callout: Font     = .system(size: 15, weight: .regular)
        static let subheadline: Font = .system(size: 14, weight: .regular)
        static let footnote: Font    = .system(size: 13, weight: .regular)
        static let caption1: Font    = .system(size: 12, weight: .regular)
        static let caption2: Font    = .system(size: 11, weight: .regular)
        static let mono: Font        = .system(size: 13, design: .monospaced)
    }

    // MARK: - Spacing (4pt base unit)

    enum Spacing {
        static let space1: CGFloat  = 4
        static let space2: CGFloat  = 8
        static let space3: CGFloat  = 12
        static let space4: CGFloat  = 16
        static let space5: CGFloat  = 20
        static let space6: CGFloat  = 24
        static let space8: CGFloat  = 32
        static let space10: CGFloat = 40
        static let space12: CGFloat = 48
        static let sm: CGFloat = 4
        static let md: CGFloat = 12
        static let lg: CGFloat = 24
    }

    enum Radius {
        static let `default`: CGFloat = 2
        static let sm: CGFloat = 2
        static let md: CGFloat = 3
        static let lg: CGFloat = 4
    }

    enum Shadow {
        private static let smLight = Color.black.opacity(0.08)
        private static let smDark  = Color.black.opacity(0.25)
        private static let mdLight = Color.black.opacity(0.10)
        private static let mdDark  = Color.black.opacity(0.35)
        private static let lgLight = Color.black.opacity(0.12)
        private static let lgDark  = Color.black.opacity(0.45)

        static func sm(_ s: ColorScheme) -> Color { s == .dark ? smDark : smLight }
        static func md(_ s: ColorScheme) -> Color { s == .dark ? mdDark : mdLight }
        static func lg(_ s: ColorScheme) -> Color { s == .dark ? lgDark : lgLight }
    }

    enum Animation {
        static let fast: SwiftUI.Animation   = .easeInOut(duration: 0.1)
        static let normal: SwiftUI.Animation = .easeInOut(duration: 0.15)
        static let slow: SwiftUI.Animation   = .easeInOut(duration: 0.25)
        static let durationFast: Double   = 0.1
        static let durationNormal: Double = 0.15
        static let durationSlow: Double   = 0.25
    }

    enum Layout {
        static let sidebarWidth: CGFloat     = 240
        static let sidebarNarrow: CGFloat    = 200
        static let sidebarWide: CGFloat      = 300
        static let sidebarCollapsed: CGFloat = 40
    }
}

// MARK: - Configurable Accent

class CatalystAccent: ObservableObject {
    @Published var color: Catalyst.AccentColor = Catalyst.primary

    func fill(_ s: ColorScheme) -> Color   { color.fill(s) }
    func hover(_ s: ColorScheme) -> Color  { color.hover(s) }
    func subtle(_ s: ColorScheme) -> Color { color.subtle(s) }
    func text(_ s: ColorScheme) -> Color   { color.text(s) }
}

private struct CatalystAccentKey: EnvironmentKey {
    static let defaultValue = CatalystAccent()
}

extension EnvironmentValues {
    var catalystAccent: CatalystAccent {
        get { self[CatalystAccentKey.self] }
        set { self[CatalystAccentKey.self] = newValue }
    }
}
