import SwiftUI

// MARK: - Tabs

struct CatalystTabs: View {
    let items: [String]
    @Binding var selected: Int

    @Environment(\.colorScheme) private var scheme
    @Environment(\.catalystAccent) private var accent

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                CatalystTabItem(
                    title: items[index], isActive: selected == index,
                    accentColor: accent.fill(scheme)
                ) { withAnimation(Catalyst.Animation.fast) { selected = index } }
            }
        }
        .overlay(alignment: .bottom) { Catalyst.Border.primary(scheme).frame(height: 1) }
    }
}

private struct CatalystTabItem: View {
    let title: String
    let isActive: Bool
    let accentColor: Color
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Catalyst.Typography.callout)
                .foregroundColor(isActive ? Catalyst.Text.primary(scheme) : Catalyst.Text.secondary(scheme))
                .padding(.horizontal, Catalyst.Spacing.space3)
                .padding(.vertical, Catalyst.Spacing.space2)
                .frame(maxHeight: .infinity)
                .background(isHovered && !isActive ? Catalyst.Surface.overlay(scheme) : Color.clear)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(isActive ? accentColor : Color.clear).frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
    }
}

// MARK: - Nav List

struct CatalystNavSection: Identifiable {
    let id: String
    let header: String?
    let items: [CatalystNavItem]

    init(header: String? = nil, items: [CatalystNavItem]) {
        self.id = header ?? items.first?.id ?? UUID().uuidString
        self.header = header; self.items = items
    }
}

struct CatalystNavItem: Identifiable, Equatable {
    let id: String
    let label: String
    let icon: String?
    init(id: String, label: String, icon: String? = nil) {
        self.id = id; self.label = label; self.icon = icon
    }
}

struct CatalystNavList: View {
    let sections: [CatalystNavSection]
    @Binding var activeID: String

    @Environment(\.colorScheme) private var scheme
    @Environment(\.catalystAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { sectionIndex, section in
                if let header = section.header {
                    if sectionIndex > 0 {
                        Catalyst.Border.primary(scheme).frame(height: 1)
                            .padding(.top, Catalyst.Spacing.space3)
                            .padding(.bottom, Catalyst.Spacing.space1)
                    }
                    Text(header)
                        .font(Catalyst.Typography.caption1).fontWeight(.semibold)
                        .foregroundColor(Catalyst.Text.tertiary(scheme))
                        .textCase(.uppercase).tracking(0.4)
                        .padding(.horizontal, Catalyst.Spacing.space3)
                        .padding(.top, Catalyst.Spacing.space2)
                        .padding(.bottom, Catalyst.Spacing.space1)
                }
                ForEach(section.items) { item in
                    CatalystNavRow(
                        item: item, isActive: activeID == item.id,
                        isIndented: section.header != nil,
                        accentSubtle: accent.subtle(scheme),
                        accentText: accent.text(scheme)
                    ) { activeID = item.id }
                }
            }
        }
        .padding(Catalyst.Spacing.space1)
    }
}

private struct CatalystNavRow: View {
    let item: CatalystNavItem
    let isActive: Bool
    let isIndented: Bool
    let accentSubtle: Color
    let accentText: Color
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Catalyst.Spacing.space2) {
                if let icon = item.icon { Image(systemName: icon).frame(width: 16) }
                Text(item.label).font(Catalyst.Typography.callout).fontWeight(isActive ? .semibold : .regular)
                Spacer()
            }
            .foregroundColor(isActive ? accentText : isHovered ? Catalyst.Text.primary(scheme) : Catalyst.Text.secondary(scheme))
            .padding(.vertical, Catalyst.Spacing.space2)
            .padding(.leading, isIndented ? Catalyst.Spacing.space5 : Catalyst.Spacing.space3)
            .padding(.trailing, Catalyst.Spacing.space3)
            .background(
                RoundedRectangle(cornerRadius: Catalyst.Radius.default)
                    .fill(isActive ? accentSubtle : isHovered ? Catalyst.Surface.overlay(scheme) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
    }
}

// MARK: - Breadcrumbs

struct CatalystBreadcrumbs: View {
    let items: [(label: String, id: String?)]
    var onNavigate: ((String) -> Void)?

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Text("/").font(Catalyst.Typography.caption1)
                        .foregroundColor(Catalyst.Text.tertiary(scheme))
                        .padding(.horizontal, Catalyst.Spacing.space2)
                }
                if index == items.count - 1 {
                    Text(item.label).font(Catalyst.Typography.footnote).fontWeight(.medium)
                        .foregroundColor(Catalyst.Text.primary(scheme))
                } else if let id = item.id {
                    Button(item.label) { onNavigate?(id) }
                        .font(Catalyst.Typography.footnote)
                        .foregroundColor(Catalyst.Text.secondary(scheme))
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                } else {
                    Text(item.label).font(Catalyst.Typography.footnote)
                        .foregroundColor(Catalyst.Text.secondary(scheme))
                }
            }
        }
        .frame(minHeight: 24)
    }
}
