import SwiftUI

// MARK: - Text Color Modifiers

extension View {
    func catalystText(_ scheme: ColorScheme) -> some View {
        foregroundColor(Catalyst.Text.primary(scheme))
    }
    func catalystTextSecondary(_ scheme: ColorScheme) -> some View {
        foregroundColor(Catalyst.Text.secondary(scheme))
    }
    func catalystTextAccent(_ accent: Catalyst.AccentColor, scheme: ColorScheme) -> some View {
        foregroundColor(accent.text(scheme))
    }
}

// MARK: - Background Modifiers

extension View {
    func catalystBg(_ scheme: ColorScheme) -> some View {
        background(Catalyst.Surface.bg(scheme))
    }
    func catalystSurface(_ scheme: ColorScheme) -> some View {
        background(Catalyst.Surface.surface(scheme))
    }
    func catalystSubtle(_ accent: Catalyst.AccentColor, scheme: ColorScheme) -> some View {
        background(accent.subtle(scheme))
    }
}

// MARK: - Catalyst Border Modifier

struct CatalystBorderModifier: ViewModifier {
    let scheme: ColorScheme
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(Catalyst.Border.primary(scheme), lineWidth: 1)
            )
            .cornerRadius(radius)
    }
}

extension View {
    func catalystBorder(_ scheme: ColorScheme, radius: CGFloat = Catalyst.Radius.default) -> some View {
        modifier(CatalystBorderModifier(scheme: scheme, radius: radius))
    }
}

// MARK: - Shadow Modifier

extension View {
    func catalystShadow(_ level: CatalystShadowLevel = .md, scheme: ColorScheme) -> some View {
        switch level {
        case .sm: return shadow(color: Catalyst.Shadow.sm(scheme), radius: 2, y: 1)
        case .md: return shadow(color: Catalyst.Shadow.md(scheme), radius: 6, y: 2)
        case .lg: return shadow(color: Catalyst.Shadow.lg(scheme), radius: 12, y: 4)
        }
    }
}

enum CatalystShadowLevel {
    case sm, md, lg
}

// MARK: - State Modifiers

extension View {
    func catalystDisabled(_ isDisabled: Bool) -> some View {
        self.opacity(isDisabled ? 0.5 : 1.0)
            .allowsHitTesting(!isDisabled)
    }
    func catalystLoading(_ isLoading: Bool) -> some View {
        self.opacity(isLoading ? 0.6 : 1.0)
            .allowsHitTesting(!isLoading)
    }
}

// MARK: - Table Helpers

struct CatalystTableHeader: View {
    let columns: [String]

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.self) { col in
                Text(col)
                    .font(Catalyst.Typography.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(Catalyst.Text.secondary(scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Catalyst.Spacing.space3)
                    .padding(.vertical, Catalyst.Spacing.space2)
            }
        }
        .background(Catalyst.Surface.raised(scheme))
        .overlay(alignment: .bottom) {
            Catalyst.Border.primary(scheme).frame(height: 1)
        }
    }
}

struct CatalystTableRow<Content: View>: View {
    let content: () -> Content

    @Environment(\.colorScheme) private var scheme
    @State private var isHovered = false

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        HStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, Catalyst.Spacing.space3)
        .padding(.vertical, Catalyst.Spacing.space2)
        .frame(maxWidth: .infinity)
        .background(isHovered ? Catalyst.primary.subtle(scheme) : Color.clear)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Catalyst.Border.primary(scheme).frame(height: 1)
        }
        .onHover { isHovered = $0 }
    }
}
