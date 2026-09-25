import SwiftUI

// MARK: - Sort Order

enum CatalystSortOrder { case none, ascending, descending }

// MARK: - Column Definition

struct CatalystDataTableColumn: Identifiable {
    let id: String
    let title: String
    let sortable: Bool
    init(_ title: String, id: String? = nil, sortable: Bool = true) {
        self.id = id ?? title; self.title = title; self.sortable = sortable
    }
}

// MARK: - Data Table

struct CatalystDataTable<RowData: Identifiable>: View {
    let columns: [CatalystDataTableColumn]
    let rows: [RowData]
    let searchableKeys: ((RowData) -> String)?
    let cellContent: (RowData, CatalystDataTableColumn) -> AnyView

    @State private var sortColumn: String?
    @State private var sortOrder: CatalystSortOrder = .none
    @State private var searchQuery = ""
    @State private var currentPage = 0
    @State private var entriesPerPage = 10
    @Environment(\.colorScheme) private var scheme

    private let pageSizeOptions = [5, 10, 25, 50]

    init(
        columns: [CatalystDataTableColumn],
        rows: [RowData],
        searchableKeys: ((RowData) -> String)? = nil,
        cellContent: @escaping (RowData, CatalystDataTableColumn) -> AnyView
    ) {
        self.columns = columns
        self.rows = rows
        self.searchableKeys = searchableKeys
        self.cellContent = cellContent
    }

    private var filteredRows: [RowData] {
        guard let searchableKeys, !searchQuery.isEmpty else { return rows }
        return rows.filter { searchableKeys($0).localizedCaseInsensitiveContains(searchQuery) }
    }

    private var totalPages: Int {
        max(1, Int(ceil(Double(filteredRows.count) / Double(entriesPerPage))))
    }

    private var pagedRows: [RowData] {
        let start = currentPage * entriesPerPage
        let end = min(start + entriesPerPage, filteredRows.count)
        guard start < filteredRows.count else { return [] }
        return Array(filteredRows[start..<end])
    }

    private var showingRange: String {
        guard !filteredRows.isEmpty else { return "0 entries" }
        let start = currentPage * entriesPerPage + 1
        let end = min(start + entriesPerPage - 1, filteredRows.count)
        return "\(start)–\(end) of \(filteredRows.count)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar: entries selector + search
            HStack {
                // Entries per page
                HStack(spacing: Catalyst.Spacing.space2) {
                    Text("Show")
                        .font(Catalyst.Typography.footnote)
                        .foregroundColor(Catalyst.Text.secondary(scheme))
                    Picker("", selection: $entriesPerPage) {
                        ForEach(pageSizeOptions, id: \.self) { n in
                            Text("\(n)").tag(n)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .focusEffectDisabled()
                    .onChange(of: entriesPerPage) { currentPage = 0 }
                    Text("entries")
                        .font(Catalyst.Typography.footnote)
                        .foregroundColor(Catalyst.Text.secondary(scheme))
                }

                Spacer()

                // Search
                if searchableKeys != nil {
                    HStack(spacing: Catalyst.Spacing.space2) {
                        Text("Search:")
                            .font(Catalyst.Typography.footnote)
                            .foregroundColor(Catalyst.Text.secondary(scheme))
                        TextField("", text: $searchQuery)
                            .textFieldStyle(CatalystTextFieldStyle())
                            .frame(width: 180)
                            .onChange(of: searchQuery) { currentPage = 0 }
                    }
                }
            }
            .padding(.horizontal, Catalyst.Spacing.space3)
            .padding(.vertical, Catalyst.Spacing.space2)
            .background(Catalyst.Surface.surface(scheme))
            .overlay(alignment: .bottom) { Catalyst.Border.primary(scheme).frame(height: 1) }

            // Column headers
            HStack(spacing: 0) {
                ForEach(columns) { col in
                    DataTableHeaderCell(
                        column: col,
                        isSorted: sortColumn == col.id,
                        sortOrder: sortColumn == col.id ? sortOrder : .none
                    ) {
                        if col.sortable {
                            if sortColumn == col.id {
                                sortOrder = sortOrder == .ascending ? .descending : .ascending
                            } else {
                                sortColumn = col.id; sortOrder = .ascending
                            }
                        }
                    }
                }
            }
            .background(Catalyst.Surface.raised(scheme))
            .overlay(alignment: .bottom) { Catalyst.Border.primary(scheme).frame(height: 1) }

            // Rows
            if pagedRows.isEmpty {
                Text("No matching entries")
                    .font(Catalyst.Typography.callout)
                    .foregroundColor(Catalyst.Text.tertiary(scheme))
                    .frame(maxWidth: .infinity)
                    .padding(Catalyst.Spacing.space6)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(pagedRows) { row in
                        DataTableRow(columns: columns, row: row, cellContent: cellContent)
                    }
                }
            }

            // Footer: showing range + pagination
            HStack {
                Text(showingRange)
                    .font(Catalyst.Typography.footnote)
                    .foregroundColor(Catalyst.Text.secondary(scheme))

                Spacer()

                HStack(spacing: Catalyst.Spacing.space1) {
                    PaginationButton(label: "Previous", enabled: currentPage > 0) {
                        currentPage -= 1
                    }
                    ForEach(0..<totalPages, id: \.self) { page in
                        PaginationPageButton(page: page, isActive: page == currentPage) {
                            currentPage = page
                        }
                    }
                    PaginationButton(label: "Next", enabled: currentPage < totalPages - 1) {
                        currentPage += 1
                    }
                }
            }
            .padding(.horizontal, Catalyst.Spacing.space3)
            .padding(.vertical, Catalyst.Spacing.space2)
            .background(Catalyst.Surface.surface(scheme))
            .overlay(alignment: .top) { Catalyst.Border.primary(scheme).frame(height: 1) }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Catalyst.Radius.default)
                .stroke(Catalyst.Border.primary(scheme), lineWidth: 1)
        )
        .cornerRadius(Catalyst.Radius.default)
    }
}

// MARK: - Header Cell

private struct DataTableHeaderCell: View {
    let column: CatalystDataTableColumn
    let isSorted: Bool
    let sortOrder: CatalystSortOrder
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Catalyst.Spacing.space1) {
                Text(column.title)
                    .font(Catalyst.Typography.subheadline).fontWeight(.semibold)
                    .foregroundColor(Catalyst.Text.secondary(scheme))

                if column.sortable {
                    VStack(spacing: 0) {
                        Text("↑")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(isSorted && sortOrder == .ascending ? Catalyst.Text.primary(scheme) : Catalyst.Text.tertiary(scheme))
                        Text("↓")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(isSorted && sortOrder == .descending ? Catalyst.Text.primary(scheme) : Catalyst.Text.tertiary(scheme))
                    }
                    .frame(width: 10)
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Catalyst.Spacing.space3)
        .padding(.vertical, Catalyst.Spacing.space2)
        .background(isHovered && column.sortable ? Catalyst.Surface.overlay(scheme) : Color.clear)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Data Row

private struct DataTableRow<RowData: Identifiable>: View {
    let columns: [CatalystDataTableColumn]
    let row: RowData
    let cellContent: (RowData, CatalystDataTableColumn) -> AnyView

    @Environment(\.colorScheme) private var scheme
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns) { col in
                cellContent(row, col)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Catalyst.Spacing.space3)
                    .padding(.vertical, Catalyst.Spacing.space2)
            }
        }
        .background(isHovered ? Catalyst.primary.subtle(scheme) : Color.clear)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Catalyst.Border.primary(scheme).frame(height: 1) }
        .onHover { isHovered = $0 }
    }
}

// MARK: - Pagination Controls

private struct PaginationButton: View {
    let label: String
    let enabled: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Catalyst.Typography.footnote)
                .foregroundColor(enabled ? Catalyst.Text.primary(scheme) : Catalyst.Text.tertiary(scheme))
                .padding(.horizontal, Catalyst.Spacing.space2)
                .padding(.vertical, Catalyst.Spacing.space1)
                .background(
                    RoundedRectangle(cornerRadius: Catalyst.Radius.default)
                        .fill(Catalyst.Surface.raised(scheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Catalyst.Radius.default)
                        .stroke(Catalyst.Border.primary(scheme), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!enabled)
    }
}

private struct PaginationPageButton: View {
    let page: Int
    let isActive: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.catalystAccent) private var accent

    var body: some View {
        Button(action: action) {
            Text("\(page + 1)")
                .font(Catalyst.Typography.footnote)
                .fontWeight(isActive ? .semibold : .regular)
                .foregroundColor(isActive ? Catalyst.Text.onAccent : Catalyst.Text.primary(scheme))
                .frame(minWidth: 24, minHeight: 24)
                .background(
                    RoundedRectangle(cornerRadius: Catalyst.Radius.default)
                        .fill(isActive ? accent.fill(scheme) : Catalyst.Surface.raised(scheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Catalyst.Radius.default)
                        .stroke(isActive ? accent.fill(scheme) : Catalyst.Border.primary(scheme), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}
