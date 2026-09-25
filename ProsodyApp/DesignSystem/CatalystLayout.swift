import SwiftUI

// MARK: - App Shell

/// The root layout container. Mirrors `ctl-app-shell` — sidebar + scrollable main.
/// Uses NavigationSplitView on iOS 16+ / macOS 13+.
struct CatalystAppShell<Sidebar: View, Content: View>: View {
    let sidebar: () -> Sidebar
    let content: () -> Content

    @Environment(\.colorScheme) private var scheme
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic

    init(
        @ViewBuilder sidebar: @escaping () -> Sidebar,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.sidebar = sidebar
        self.content = content
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar()
                .frame(minWidth: Catalyst.Layout.sidebarNarrow, idealWidth: Catalyst.Layout.sidebarWidth)
                .background(Catalyst.Surface.surface(scheme))
                #if os(macOS)
                .navigationSplitViewColumnWidth(
                    min: Catalyst.Layout.sidebarNarrow,
                    ideal: Catalyst.Layout.sidebarWidth,
                    max: Catalyst.Layout.sidebarWide
                )
                #endif
        } detail: {
            ScrollView {
                content()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(Catalyst.Spacing.lg)
            }
            .background(Catalyst.Surface.bg(scheme))
        }
        .navigationSplitViewStyle(.balanced)
    }
}

/// Simpler shell for sidebar + detail without NavigationSplitView (e.g., embedded views).
struct CatalystHSplitShell<Sidebar: View, Content: View>: View {
    let sidebarWidth: CGFloat
    let sidebar: () -> Sidebar
    let content: () -> Content

    @Environment(\.colorScheme) private var scheme

    init(
        sidebarWidth: CGFloat = Catalyst.Layout.sidebarWidth,
        @ViewBuilder sidebar: @escaping () -> Sidebar,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.sidebarWidth = sidebarWidth
        self.sidebar = sidebar
        self.content = content
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar()
                .frame(width: sidebarWidth)
                .background(Catalyst.Surface.surface(scheme))
                .overlay(alignment: .trailing) {
                    Catalyst.Border.primary(scheme).frame(width: 1)
                }
            ScrollView {
                content()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(Catalyst.Spacing.lg)
            }
            .background(Catalyst.Surface.bg(scheme))
        }
    }
}

// MARK: - Sidebar Container

struct CatalystSidebar<Content: View>: View {
    let title: String?
    let content: () -> Content

    @Environment(\.colorScheme) private var scheme

    init(title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
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
                    .overlay(alignment: .bottom) {
                        Catalyst.Border.primary(scheme).frame(height: 1)
                    }
            }
            ScrollView {
                content()
            }
        }
    }
}

// MARK: - Toolbar

struct CatalystToolbar<Leading: View, Trailing: View>: View {
    let leading: () -> Leading
    let trailing: () -> Trailing

    @Environment(\.colorScheme) private var scheme

    init(
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: Catalyst.Spacing.space3) {
            leading()
            Spacer()
            trailing()
        }
        .padding(.horizontal, Catalyst.Spacing.space3)
        .padding(.vertical, Catalyst.Spacing.space2)
        .background(Catalyst.Surface.surface(scheme))
        .overlay(alignment: .bottom) {
            Catalyst.Border.primary(scheme).frame(height: 1)
        }
    }
}

// MARK: - Status Bar

struct CatalystStatusBar<Content: View>: View {
    let content: () -> Content

    @Environment(\.colorScheme) private var scheme

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        HStack(spacing: Catalyst.Spacing.space3) {
            content()
        }
        .font(Catalyst.Typography.footnote)
        .foregroundColor(Catalyst.Text.secondary(scheme))
        .padding(.horizontal, Catalyst.Spacing.space3)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(Catalyst.Surface.surface(scheme))
        .overlay(alignment: .top) {
            Catalyst.Border.primary(scheme).frame(height: 1)
        }
    }
}

// MARK: - Grid Utilities

struct CatalystGrid<Content: View>: View {
    let columns: Int
    let spacing: CGFloat
    let content: () -> Content

    init(columns: Int = 2, spacing: CGFloat = Catalyst.Spacing.md, @ViewBuilder content: @escaping () -> Content) {
        self.columns = columns
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
            spacing: spacing
        ) {
            content()
        }
    }
}

/// Adaptive grid — auto-fill columns with a minimum width (like `ctl-grid-auto`).
struct CatalystAdaptiveGrid<Content: View>: View {
    let minWidth: CGFloat
    let spacing: CGFloat
    let content: () -> Content

    init(minWidth: CGFloat = 280, spacing: CGFloat = Catalyst.Spacing.md, @ViewBuilder content: @escaping () -> Content) {
        self.minWidth = minWidth
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: minWidth), spacing: spacing)],
            spacing: spacing
        ) {
            content()
        }
    }
}

// MARK: - Divider

struct CatalystDivider: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Catalyst.Border.primary(scheme)
            .frame(height: 1)
            .padding(.vertical, Catalyst.Spacing.space4)
    }
}
