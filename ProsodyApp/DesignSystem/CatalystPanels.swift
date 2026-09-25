import SwiftUI

// MARK: - Panel

struct CatalystPanel<Content: View>: View {
    let title: String?
    let isRaised: Bool
    let content: () -> Content

    @Environment(\.colorScheme) private var scheme

    init(title: String? = nil, raised: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.isRaised = raised; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(Catalyst.Typography.headline)
                    .foregroundColor(Catalyst.Text.primary(scheme))
                    .padding(.horizontal, Catalyst.Spacing.space3)
                    .padding(.vertical, Catalyst.Spacing.space2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Catalyst.Surface.surface(scheme))
                    .overlay(alignment: .bottom) { Catalyst.Border.primary(scheme).frame(height: 1) }
            }
            content()
                .padding(Catalyst.Spacing.space3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isRaised ? Catalyst.Surface.raised(scheme) : Catalyst.Surface.bg(scheme))
        .overlay(RoundedRectangle(cornerRadius: Catalyst.Radius.default).stroke(Catalyst.Border.primary(scheme), lineWidth: 1))
        .cornerRadius(Catalyst.Radius.default)
    }
}

// MARK: - Accordion

struct CatalystAccordion<Content: View>: View {
    let title: String
    @State private var isExpanded = false
    let content: () -> Content

    @Environment(\.colorScheme) private var scheme

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(Catalyst.Animation.fast) { isExpanded.toggle() }
            } label: {
                HStack {
                    Text(isExpanded ? "▾" : "▸").font(Catalyst.Typography.caption1)
                        .foregroundColor(Catalyst.Text.tertiary(scheme)).frame(width: 16)
                    Text(title).font(Catalyst.Typography.body).fontWeight(.medium)
                        .foregroundColor(Catalyst.Text.primary(scheme))
                    Spacer()
                }
                .padding(.horizontal, Catalyst.Spacing.space3)
                .padding(.vertical, Catalyst.Spacing.space2)
                .background(Catalyst.Surface.surface(scheme))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            if isExpanded { content().padding(Catalyst.Spacing.space3) }
        }
        .overlay(RoundedRectangle(cornerRadius: Catalyst.Radius.default).stroke(Catalyst.Border.primary(scheme), lineWidth: 1))
        .cornerRadius(Catalyst.Radius.default)
    }
}

// MARK: - Progress Bar

struct CatalystProgressBar: View {
    let value: Double

    @Environment(\.colorScheme) private var scheme
    @Environment(\.catalystAccent) private var accent

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Catalyst.Radius.default).fill(Catalyst.Surface.raised(scheme))
                RoundedRectangle(cornerRadius: Catalyst.Radius.default)
                    .fill(accent.fill(scheme))
                    .frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 4)
        .animation(Catalyst.Animation.normal, value: value)
    }
}
