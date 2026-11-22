import SwiftUI

/// Edits a table of a note as a grid of fields: header and cells, rows and columns added or removed, the alignment
/// of each column. The note keeps the table as Markdown (`MarkdownTable.markdown`); this is only a nicer way to
/// write it. The same view on iOS (a sheet) and the Mac (a sheet of the window).
struct TableEditorView: View {
    @State private var table: MarkdownTable
    let isNew: Bool
    /// The new table; nil = cancelled. `delete` = the table is to go.
    let finish: (_ table: MarkdownTable?, _ delete: Bool) -> Void

    init(table: MarkdownTable, isNew: Bool, finish: @escaping (_ table: MarkdownTable?, _ delete: Bool) -> Void) {
        _table = State(initialValue: table)
        self.isNew = isNew
        self.finish = finish
    }

    private let cellWidth: CGFloat = 130

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { finish(nil, false) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text(isNew ? "New Table" : "Edit Table").font(.headline)
                Spacer()
                Button("Done") { finish(table, false) }
                    .fontWeight(.semibold)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(table.header.indices), id: \.self) { column in
                            columnMenu(column).frame(width: cellWidth)
                        }
                        Color.clear.frame(width: 28, height: 1)
                    }
                    GridRow {
                        ForEach(Array(table.header.indices), id: \.self) { column in
                            TextField("Header", text: headerBinding(column))
                                .fontWeight(.semibold)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: cellWidth)
                        }
                        Color.clear.frame(width: 28, height: 1)
                    }
                    ForEach(Array(table.rows.indices), id: \.self) { row in
                        GridRow {
                            ForEach(Array(table.header.indices), id: \.self) { column in
                                TextField("", text: cellBinding(row, column))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: cellWidth)
                            }
                            rowMenu(row)
                        }
                    }
                }
                .padding()
            }
            Divider()
            HStack(spacing: 16) {
                Button { table.addRow() } label: { Label("Add Row", systemImage: "plus") }
                Button { table.addColumn() } label: { Label("Add Column", systemImage: "plus") }
                Spacer()
                Button(role: .destructive) { finish(nil, true) } label: { Label("Delete Table", systemImage: "trash") }
            }
            .padding()
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 340, idealHeight: 420)
        #endif
    }

    private func headerBinding(_ column: Int) -> Binding<String> {
        Binding(
            get: { table.header.indices.contains(column) ? table.header[column] : "" },
            set: { if table.header.indices.contains(column) { table.header[column] = $0 } }
        )
    }

    private func cellBinding(_ row: Int, _ column: Int) -> Binding<String> {
        Binding(
            get: { table.rows.indices.contains(row) && table.rows[row].indices.contains(column) ? table.rows[row][column] : "" },
            set: { if table.rows.indices.contains(row), table.rows[row].indices.contains(column) { table.rows[row][column] = $0 } }
        )
    }

    private func columnMenu(_ column: Int) -> some View {
        Menu {
            Picker("Alignment", selection: Binding(
                get: { table.alignments.indices.contains(column) ? table.alignments[column] : .none },
                set: { if table.alignments.indices.contains(column) { table.alignments[column] = $0 } }
            )) {
                Label("Left", systemImage: "text.alignleft").tag(MarkdownTable.Alignment.left)
                Label("Center", systemImage: "text.aligncenter").tag(MarkdownTable.Alignment.center)
                Label("Right", systemImage: "text.alignright").tag(MarkdownTable.Alignment.right)
                Text("Default").tag(MarkdownTable.Alignment.none)
            }
            Divider()
            Button { table.addColumn(at: column) } label: { Label("Insert Column Before", systemImage: "arrow.left.to.line") }
            Button { table.addColumn(at: column + 1) } label: { Label("Insert Column After", systemImage: "arrow.right.to.line") }
            if table.columnCount > 1 {
                Divider()
                Button(role: .destructive) { table.removeColumn(at: column) } label: { Label("Delete Column", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(maxWidth: .infinity)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Column \(column + 1)")
    }

    private func rowMenu(_ row: Int) -> some View {
        Menu {
            Button { table.addRow(at: row) } label: { Label("Insert Row Above", systemImage: "arrow.up.to.line") }
            Button { table.addRow(at: row + 1) } label: { Label("Insert Row Below", systemImage: "arrow.down.to.line") }
            Divider()
            Button(role: .destructive) { table.removeRow(at: row) } label: { Label("Delete Row", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .frame(width: 28)
        .accessibilityLabel("Row \(row + 1)")
    }
}
