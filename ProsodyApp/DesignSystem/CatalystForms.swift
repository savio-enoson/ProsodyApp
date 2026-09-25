import SwiftUI

struct CatalystFormGroup<Content: View>: View {
    let label: String
    let hint: String?
    let error: String?
    let content: () -> Content

    @Environment(\.colorScheme) private var scheme

    init(label: String, hint: String? = nil, error: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.label = label; self.hint = hint; self.error = error; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Catalyst.Spacing.space1) {
            Text(label)
                .font(Catalyst.Typography.subheadline).fontWeight(.medium)
                .foregroundColor(Catalyst.Text.secondary(scheme))
            content()
            if let error {
                Text(error).font(Catalyst.Typography.caption1).foregroundColor(Catalyst.danger.text(scheme))
            } else if let hint {
                Text(hint).font(Catalyst.Typography.caption1).foregroundColor(Catalyst.Text.tertiary(scheme))
            }
        }
        .padding(.bottom, Catalyst.Spacing.space3)
    }
}

struct CatalystTextFieldStyle: TextFieldStyle {
    let isError: Bool
    @Environment(\.colorScheme) private var scheme
    @FocusState private var isFocused: Bool

    init(isError: Bool = false) { self.isError = isError }

    private var borderColor: Color {
        if isError { return Catalyst.danger.fill(scheme) }
        if isFocused { return Catalyst.primary.fill(scheme) }
        return Catalyst.Border.primary(scheme)
    }

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .focused($isFocused)
            .font(Catalyst.Typography.body)
            .padding(.vertical, Catalyst.Spacing.space1 + 2)
            .padding(.horizontal, Catalyst.Spacing.space2)
            .frame(minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: Catalyst.Radius.default)
                    .fill(Catalyst.Surface.bg(scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Catalyst.Radius.default)
                    .stroke(borderColor, lineWidth: 1)
            )
            .focusEffectDisabled()
    }
}
