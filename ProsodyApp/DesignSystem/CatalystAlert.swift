import SwiftUI

// MARK: - Alert Banner

enum CatalystAlertType {
    case success, danger, warning, info

    var icon: String {
        switch self {
        case .success: return "✓"
        case .danger:  return "✕"
        case .warning: return "!"
        case .info:    return "ℹ"
        }
    }

    func accentColor() -> Catalyst.AccentColor {
        switch self {
        case .success: return Catalyst.success
        case .danger:  return Catalyst.danger
        case .warning: return Catalyst.warning
        case .info:    return Catalyst.info
        }
    }
}

struct CatalystAlertBanner: View {
    let type: CatalystAlertType
    let title: String?
    let message: String
    let closable: Bool
    var onDismiss: (() -> Void)?

    @Environment(\.colorScheme) private var scheme

    init(
        _ type: CatalystAlertType,
        message: String,
        title: String? = nil,
        closable: Bool = false,
        onDismiss: (() -> Void)? = nil
    ) {
        self.type = type
        self.message = message
        self.title = title
        self.closable = closable
        self.onDismiss = onDismiss
    }

    var body: some View {
        let accent = type.accentColor()
        HStack(alignment: .top, spacing: Catalyst.Spacing.space3) {
            Text(type.icon)
                .font(Catalyst.Typography.body)
                .fontWeight(.semibold)
                .foregroundColor(accent.text(scheme))
                .frame(width: 24, height: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .font(Catalyst.Typography.callout)
                        .fontWeight(.semibold)
                        .foregroundColor(Catalyst.Text.primary(scheme))
                }
                Text(message)
                    .font(Catalyst.Typography.footnote)
                    .foregroundColor(Catalyst.Text.secondary(scheme))
            }

            Spacer(minLength: 0)

            if closable {
                Button { onDismiss?() } label: {
                    Text("✕")
                        .font(Catalyst.Typography.footnote)
                        .foregroundColor(Catalyst.Text.tertiary(scheme))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .padding(.horizontal, Catalyst.Spacing.space4)
        .padding(.vertical, Catalyst.Spacing.space3)
        .background(accent.subtle(scheme))
        .overlay(
            RoundedRectangle(cornerRadius: Catalyst.Radius.default)
                .stroke(accent.fill(scheme), lineWidth: 1)
        )
        .cornerRadius(Catalyst.Radius.default)
    }
}
