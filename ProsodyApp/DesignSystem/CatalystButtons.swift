import SwiftUI

// MARK: - Button Styles

enum CatalystButtonRole: Equatable {
    case `default`, primary, danger, success, warning, ghost
}

enum CatalystButtonSize: Equatable {
    case sm, md, lg

    var verticalPadding: CGFloat {
        switch self { case .sm: 0; case .md: Catalyst.Spacing.space1; case .lg: Catalyst.Spacing.space2 }
    }
    var horizontalPadding: CGFloat {
        switch self { case .sm: Catalyst.Spacing.space2; case .md: Catalyst.Spacing.space3; case .lg: Catalyst.Spacing.space4 }
    }
    var font: Font {
        switch self { case .sm: Catalyst.Typography.footnote; case .md: Catalyst.Typography.callout; case .lg: Catalyst.Typography.body }
    }
    var minHeight: CGFloat {
        switch self { case .sm: 24; case .md: 30; case .lg: 36 }
    }
}

struct CatalystButton: View {
    let title: String
    let role: CatalystButtonRole
    let size: CatalystButtonSize
    let action: () -> Void

    init(_ title: String, role: CatalystButtonRole = .default, size: CatalystButtonSize = .md, action: @escaping () -> Void) {
        self.title = title; self.role = role; self.size = size; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).font(size.font).lineLimit(1)
        }
        .buttonStyle(CatalystButtonStyle(role: role, size: size))
        .focusEffectDisabled()
    }
}

struct CatalystButtonStyle: ButtonStyle {
    let role: CatalystButtonRole
    let size: CatalystButtonSize

    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .padding(.vertical, size.verticalPadding)
            .padding(.horizontal, size.horizontalPadding)
            .frame(minHeight: size.minHeight)
            .font(size.font)
            .foregroundColor(foreground)
            .background(RoundedRectangle(cornerRadius: Catalyst.Radius.default).fill(background(isPressed: pressed)))
            .overlay(RoundedRectangle(cornerRadius: Catalyst.Radius.default).stroke(borderColor, lineWidth: role == .ghost ? 0 : 1))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { isHovered = $0 }
            .animation(Catalyst.Animation.fast, value: isHovered)
    }

    private var foreground: Color {
        switch role {
        case .default: Catalyst.Text.primary(scheme)
        case .primary: Catalyst.Text.onAccent
        case .danger:  Catalyst.Text.onAccent
        case .success: Catalyst.Text.onAccent
        case .warning: Catalyst.warningOnAccent(scheme)
        case .ghost:   Catalyst.Text.primary(scheme)
        }
    }

    private func background(isPressed: Bool) -> Color {
        switch role {
        case .default:
            if isPressed { return Catalyst.Border.secondary(scheme) }
            return isHovered ? Catalyst.Border.primary(scheme) : Catalyst.Surface.raised(scheme)
        case .primary: return isPressed || isHovered ? Catalyst.primary.hover(scheme) : Catalyst.primary.fill(scheme)
        case .danger:  return isPressed || isHovered ? Catalyst.danger.hover(scheme) : Catalyst.danger.fill(scheme)
        case .success: return isPressed || isHovered ? Catalyst.success.hover(scheme) : Catalyst.success.fill(scheme)
        case .warning: return isPressed || isHovered ? Catalyst.warning.hover(scheme) : Catalyst.warning.fill(scheme)
        case .ghost:   return (isPressed || isHovered) ? Catalyst.Surface.overlay(scheme) : Color.clear
        }
    }

    private var borderColor: Color {
        switch role {
        case .default: isHovered ? Catalyst.Border.secondary(scheme) : Catalyst.Border.primary(scheme)
        case .primary: isHovered ? Catalyst.primary.hover(scheme) : Catalyst.primary.fill(scheme)
        case .danger:  isHovered ? Catalyst.danger.hover(scheme) : Catalyst.danger.fill(scheme)
        case .success: isHovered ? Catalyst.success.hover(scheme) : Catalyst.success.fill(scheme)
        case .warning: isHovered ? Catalyst.warning.hover(scheme) : Catalyst.warning.fill(scheme)
        case .ghost:   Color.clear
        }
    }
}

// MARK: - Badge

enum CatalystBadgeVariant: Equatable {
    case primary, success, warning, danger, info
    case purple, teal, orange, indigo, rose, lime, slate

    func color() -> Catalyst.AccentColor {
        switch self {
        case .primary: Catalyst.primary; case .success: Catalyst.success
        case .warning: Catalyst.warning; case .danger: Catalyst.danger
        case .info: Catalyst.info;       case .purple: Catalyst.purple
        case .teal: Catalyst.teal;       case .orange: Catalyst.orange
        case .indigo: Catalyst.indigo;   case .rose: Catalyst.rose
        case .lime: Catalyst.lime;       case .slate: Catalyst.slate
        }
    }
}

struct CatalystBadge: View, Equatable {
    let label: String
    let variant: CatalystBadgeVariant

    init(_ label: String, variant: CatalystBadgeVariant = .slate) {
        self.label = label
        self.variant = variant
    }

    init(label: String, variant: CatalystBadgeVariant = .slate) {
        self.label = label
        self.variant = variant
    }

    static func == (lhs: CatalystBadge, rhs: CatalystBadge) -> Bool {
        lhs.label == rhs.label && lhs.variant == rhs.variant
    }

    var body: some View {
        CatalystBadgeContent(label: label, variant: variant)
    }
}

private struct CatalystBadgeContent: View {
    let label: String
    let variant: CatalystBadgeVariant
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = variant.color()
        Text(label)
            .font(Catalyst.Typography.caption2).fontWeight(.medium).lineLimit(1)
            .padding(.horizontal, Catalyst.Spacing.space2)
            .frame(height: 22)
            .foregroundColor(c.text(scheme))
            .background(RoundedRectangle(cornerRadius: Catalyst.Radius.default).fill(c.subtle(scheme)))
    }
}
