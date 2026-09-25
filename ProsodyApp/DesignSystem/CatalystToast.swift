import SwiftUI
import Combine

// MARK: - Toast Model

enum CatalystToastType: Equatable {
    case success, danger, warning, info

    var icon: String {
        switch self {
        case .success: "✓"; case .danger: "✕"; case .warning: "!"; case .info: "ℹ"
        }
    }

    func accentColor() -> Catalyst.AccentColor {
        switch self {
        case .success: Catalyst.success; case .danger: Catalyst.danger
        case .warning: Catalyst.warning; case .info: Catalyst.info
        }
    }
}

struct CatalystToastItem: Identifiable, Equatable {
    let id: UUID
    let type: CatalystToastType
    let message: String
    let title: String?
    let duration: TimeInterval

    init(_ type: CatalystToastType, message: String, title: String? = nil, duration: TimeInterval = 4.0) {
        self.id = UUID(); self.type = type; self.message = message; self.title = title; self.duration = duration
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

// MARK: - Toast Manager

class CatalystToastManager: ObservableObject {
    @Published private(set) var toasts: [CatalystToastItem] = []
    private let maxVisible = 5

    func success(_ message: String, title: String? = nil, duration: TimeInterval = 4.0) {
        push(.init(.success, message: message, title: title, duration: duration))
    }
    func danger(_ message: String, title: String? = nil, duration: TimeInterval = 4.0) {
        push(.init(.danger, message: message, title: title, duration: duration))
    }
    func warning(_ message: String, title: String? = nil, duration: TimeInterval = 4.0) {
        push(.init(.warning, message: message, title: title, duration: duration))
    }
    func info(_ message: String, title: String? = nil, duration: TimeInterval = 4.0) {
        push(.init(.info, message: message, title: title, duration: duration))
    }

    func dismiss(_ id: UUID) {
        withAnimation(Catalyst.Animation.slow) { toasts.removeAll { $0.id == id } }
    }

    func dismissAll() {
        withAnimation(Catalyst.Animation.slow) { toasts.removeAll() }
    }

    private func push(_ toast: CatalystToastItem) {
        withAnimation(Catalyst.Animation.slow) {
            toasts.append(toast)
            if toasts.count > maxVisible { toasts.removeFirst() }
        }
        guard toast.duration > 0 else { return }
        let toastID = toast.id
        DispatchQueue.main.asyncAfter(deadline: .now() + toast.duration) { [weak self] in
            self?.dismiss(toastID)
        }
    }
}

// MARK: - Toast View

struct CatalystToastView: View {
    let toast: CatalystToastItem
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let accent = toast.type.accentColor()
        HStack(alignment: .top, spacing: Catalyst.Spacing.space3) {
            Text(toast.type.icon)
                .font(Catalyst.Typography.body).fontWeight(.semibold)
                .foregroundColor(accent.text(scheme))
                .frame(width: 24, height: 24)
                .background(Circle().fill(accent.subtle(scheme)))

            VStack(alignment: .leading, spacing: 2) {
                if let title = toast.title {
                    Text(title).font(Catalyst.Typography.callout).fontWeight(.semibold)
                        .foregroundColor(Catalyst.Text.primary(scheme))
                }
                Text(toast.message).font(Catalyst.Typography.footnote)
                    .foregroundColor(Catalyst.Text.secondary(scheme)).lineLimit(3)
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark").font(Catalyst.Typography.footnote)
                    .foregroundColor(Catalyst.Text.tertiary(scheme))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(.horizontal, Catalyst.Spacing.space4)
        .padding(.vertical, Catalyst.Spacing.space3)
        .background(Catalyst.Surface.surface(scheme))
        .overlay(
            RoundedRectangle(cornerRadius: Catalyst.Radius.default)
                .stroke(Catalyst.Border.primary(scheme), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            accent.fill(scheme).frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: Catalyst.Radius.default))
        }
        .cornerRadius(Catalyst.Radius.default)
        .shadow(color: Catalyst.Shadow.md(scheme), radius: 6, y: 2)
        .transition(.asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .move(edge: .trailing).combined(with: .opacity)
        ))
    }
}

// MARK: - Toast Overlay Modifier

struct CatalystToastOverlay: ViewModifier {
    @ObservedObject var manager: CatalystToastManager

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            VStack(spacing: Catalyst.Spacing.space2) {
                ForEach(manager.toasts) { toast in
                    CatalystToastView(toast: toast) { manager.dismiss(toast.id) }
                }
            }
            .frame(maxWidth: 400)
            .padding(Catalyst.Spacing.space4)
            .animation(Catalyst.Animation.slow, value: manager.toasts.map(\.id))
        }
    }
}

extension View {
    func catalystToasts(_ manager: CatalystToastManager) -> some View {
        modifier(CatalystToastOverlay(manager: manager))
    }
}
