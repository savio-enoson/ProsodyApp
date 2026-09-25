import SwiftUI
import Combine

// MARK: - Dialog Manager

/// Observable dialog state. Attach `.catalystDialogs(manager)` at the app root.
/// Present from anywhere via `manager.present(...)`.
class CatalystDialogManager: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var title = ""
    @Published private(set) var dialogBody: AnyView = AnyView(EmptyView())
    @Published private(set) var dialogFooter: AnyView = AnyView(EmptyView())

    func present<Body: View, Footer: View>(
        _ title: String,
        @ViewBuilder body: () -> Body,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.dialogBody = AnyView(body())
        self.dialogFooter = AnyView(footer())
        withAnimation(Catalyst.Animation.normal) { isPresented = true }
    }

    func dismiss() {
        withAnimation(Catalyst.Animation.normal) { isPresented = false }
    }
}

// MARK: - Root Overlay Modifier

/// Apply at the outermost level (same pattern as `.catalystToasts`).
struct CatalystDialogOverlayModifier: ViewModifier {
    @ObservedObject var manager: CatalystDialogManager

    func body(content: Content) -> some View {
        #if os(macOS)
        content.overlay {
            if manager.isPresented {
                CatalystDialogOverlay(manager: manager)
            }
        }
        #else
        content.sheet(isPresented: $manager.isPresented) {
            CatalystDialogSheet(manager: manager)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        #endif
    }
}

extension View {
    /// Attach at the app/window root. Renders dialogs above all content.
    func catalystDialogs(_ manager: CatalystDialogManager) -> some View {
        modifier(CatalystDialogOverlayModifier(manager: manager))
    }
}

// MARK: - macOS Overlay

#if os(macOS)
private struct CatalystDialogOverlay: View {
    @ObservedObject var manager: CatalystDialogManager
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { manager.dismiss() }

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text(manager.title).font(Catalyst.Typography.headline)
                        .foregroundColor(Catalyst.Text.primary(scheme))
                    Spacer()
                    Button { manager.dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(Catalyst.Typography.footnote)
                            .foregroundColor(Catalyst.Text.tertiary(scheme))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
                .padding(.horizontal, Catalyst.Spacing.space4)
                .padding(.vertical, Catalyst.Spacing.space3)
                .overlay(alignment: .bottom) { Catalyst.Border.primary(scheme).frame(height: 1) }

                // Body
                manager.dialogBody.padding(Catalyst.Spacing.space4)

                // Footer
                HStack {
                    Spacer()
                    manager.dialogFooter
                }
                .padding(.horizontal, Catalyst.Spacing.space4)
                .padding(.vertical, Catalyst.Spacing.space3)
                .background(Catalyst.Surface.surface(scheme))
                .overlay(alignment: .top) { Catalyst.Border.primary(scheme).frame(height: 1) }
            }
            .frame(minWidth: 360, idealWidth: 440, maxWidth: 520)
            .fixedSize(horizontal: false, vertical: true)
            .background(Catalyst.Surface.bg(scheme))
            .clipShape(RoundedRectangle(cornerRadius: Catalyst.Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: Catalyst.Radius.lg)
                    .stroke(Catalyst.Border.primary(scheme), lineWidth: 1)
            )
            .shadow(color: Catalyst.Shadow.lg(scheme), radius: 12)
        }
        .transition(.opacity)
    }
}
#endif

// MARK: - iOS Sheet

#if os(iOS)
private struct CatalystDialogSheet: View {
    @ObservedObject var manager: CatalystDialogManager
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(manager.title).font(Catalyst.Typography.headline)
                    .foregroundColor(Catalyst.Text.primary(scheme))
                Spacer()
                Button { manager.dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(Catalyst.Typography.footnote)
                        .foregroundColor(Catalyst.Text.tertiary(scheme))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
            .padding(.horizontal, Catalyst.Spacing.space4)
            .padding(.vertical, Catalyst.Spacing.space3)
            .overlay(alignment: .bottom) { Catalyst.Border.primary(scheme).frame(height: 1) }

            manager.dialogBody.padding(Catalyst.Spacing.space4)

            HStack {
                Spacer()
                manager.dialogFooter
            }
            .padding(.horizontal, Catalyst.Spacing.space4)
            .padding(.vertical, Catalyst.Spacing.space3)
            .background(Catalyst.Surface.surface(scheme))
            .overlay(alignment: .top) { Catalyst.Border.primary(scheme).frame(height: 1) }
        }
        .background(Catalyst.Surface.bg(scheme))
    }
}
#endif
