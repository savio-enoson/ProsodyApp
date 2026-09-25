import SwiftUI

struct CatalystAutocomplete<Item: Identifiable & CustomStringConvertible>: View {
    let placeholder: String
    let items: [Item]
    let onSelect: (Item) -> Void

    @State private var query = ""
    @State private var isOpen = false
    @State private var highlightIndex = 0
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var scheme

    private var filtered: [Item] {
        guard !query.isEmpty else { return items }
        return items.filter { $0.description.localizedCaseInsensitiveContains(query) }
    }

    private var results: [Item] { Array(filtered.prefix(8)) }

    private func selectHighlighted() {
        guard isOpen, results.indices.contains(highlightIndex) else { return }
        let item = results[highlightIndex]
        query = item.description
        isOpen = false
        isFocused = false
        onSelect(item)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(placeholder, text: $query, onEditingChanged: { editing in
                isOpen = editing && !filtered.isEmpty
            })
            .textFieldStyle(CatalystTextFieldStyle())
            .focused($isFocused)
            .onChange(of: query) {
                isOpen = !query.isEmpty && !filtered.isEmpty
                highlightIndex = 0
            }
            .onKeyPress(.downArrow) {
                guard isOpen else { return .ignored }
                highlightIndex = min(highlightIndex + 1, results.count - 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard isOpen else { return .ignored }
                highlightIndex = max(highlightIndex - 1, 0)
                return .handled
            }
            .onKeyPress(.return) {
                guard isOpen, !results.isEmpty else { return .ignored }
                selectHighlighted()
                return .handled
            }
            .onKeyPress(.escape) {
                guard isOpen else { return .ignored }
                isOpen = false
                return .handled
            }
            .onKeyPress(.tab) {
                guard isOpen, !results.isEmpty else { return .ignored }
                selectHighlighted()
                return .handled
            }

            if isOpen && !results.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                        AutocompleteRow(
                            text: item.description,
                            isHighlighted: index == highlightIndex
                        ) {
                            query = item.description
                            isOpen = false
                            onSelect(item)
                        }
                    }
                }
                .background(Catalyst.Surface.bg(scheme))
                .overlay(
                    RoundedRectangle(cornerRadius: Catalyst.Radius.default)
                        .stroke(Catalyst.Border.primary(scheme), lineWidth: 1)
                )
                .cornerRadius(Catalyst.Radius.default)
                .shadow(color: Catalyst.Shadow.md(scheme), radius: 6, y: 2)
            }
        }
    }
}

private struct AutocompleteRow: View {
    let text: String
    let isHighlighted: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(Catalyst.Typography.callout)
                .foregroundColor(Catalyst.Text.primary(scheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Catalyst.Spacing.space3)
                .padding(.vertical, Catalyst.Spacing.space1)
                .background((isHighlighted || isHovered) ? Catalyst.primary.subtle(scheme) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
    }
}
