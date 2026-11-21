import PDFKit
import SwiftData
import SwiftUI

/// The pages of a document's PDF: turn, move (drag), delete, add scanned pages, and split pages off into documents
/// of their own. Works on a copy; "Save" writes it back (`DocumentFiles.save`), and its text is read again.
struct PDFPageEditor: View {
    let note: Note

    @Environment(\.modelContext) private var context
    @Environment(ProcessingService.self) private var processing
    @Environment(\.dismiss) private var dismiss

    /// A page in the editor; its id stays while it moves.
    private struct Item: Identifiable {
        let id = UUID()
        let page: PDFPage
    }

    @State private var items: [Item] = []
    @State private var chosen = Set<UUID>()
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var changed = false
    /// Goes up when pages turn, so their pictures are drawn again.
    @State private var version = 0
    @State private var showScanner = false
    @State private var confirmSplitEvery = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else {
                    List(selection: $chosen) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            PageRow(page: item.page, number: index + 1, version: version)
                        }
                        .onMove { from, to in
                            items.move(fromOffsets: from, toOffset: to)
                            changed = true
                        }
                    }
                    .environment(\.editMode, .constant(.active))
                }
            }
            .disabled(isWorking)
            .overlay { if isWorking { ProgressView().controlSize(.large) } }
            .brandNavigationTitle("Pages")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save(close: true) } }
                        .disabled(!changed || isWorking)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { rotate(-90) } label: { Label("Rotate Left", systemImage: "rotate.left") }
                        .disabled(chosen.isEmpty)
                    Button { rotate(90) } label: { Label("Rotate Right", systemImage: "rotate.right") }
                        .disabled(chosen.isEmpty)
                    Button(role: .destructive) { deleteChosen() } label: { Label("Delete", systemImage: "trash") }
                        .disabled(chosen.isEmpty || chosen.count >= items.count)
                    Spacer()
                    Menu {
                        if DocumentScanner.isAvailable {
                            Button { showScanner = true } label: { Label("Scan More Pages", systemImage: "doc.viewfinder") }
                        }
                        Button { Task { await split(.pages(chosenIndices)) } } label: {
                            Label("Split Off Selected Pages", systemImage: "rectangle.split.2x1")
                        }
                        .disabled(chosen.isEmpty || chosen.count >= items.count)
                        Button { confirmSplitEvery = true } label: {
                            Label("Split Every Page", systemImage: "square.grid.2x2")
                        }
                        .disabled(items.count < 2)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog("Split Every Page?", isPresented: $confirmSplitEvery, titleVisibility: .visible) {
                Button("Split into \(items.count) Documents") { Task { await split(.everyPage) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This document keeps its first page; every other page becomes a document of its own in the same bowl.")
            }
            .alert("Could Not Edit Pages", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScanner { url in
                    showScanner = false
                    if let url { addPages(from: url) }
                }
                .ignoresSafeArea()
            }
        }
        .task { await load() }
        .interactiveDismissDisabled(changed)
    }

    /// The chosen pages as indices in the current order.
    private var chosenIndices: [Int] {
        items.enumerated().filter { chosen.contains($0.element.id) }.map(\.offset)
    }

    private func load() async {
        guard let file = DocumentFiles.pdf(of: note) else { dismiss(); return }
        do {
            let document = try await DocumentFiles.load(file)
            items = (0..<document.pageCount).compactMap { document.page(at: $0).map { Item(page: $0) } }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func rotate(_ degrees: Int) {
        for item in items where chosen.contains(item.id) {
            item.page.rotation = ((item.page.rotation + degrees) % 360 + 360) % 360
        }
        version += 1
        changed = true
    }

    private func deleteChosen() {
        guard chosen.count < items.count else { return }
        items.removeAll { chosen.contains($0.id) }
        chosen = []
        changed = true
    }

    private func addPages(from url: URL) {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let scanned = PDFDocument(url: url) else { return }
        for index in 0..<scanned.pageCount {
            if let page = scanned.page(at: index)?.copy() as? PDFPage { items.append(Item(page: page)) }
        }
        changed = true
    }

    /// The pages in their order, as a new document.
    private var edited: PDFDocument {
        let document = PDFDocument()
        for item in items {
            if let page = item.page.copy() as? PDFPage { document.insert(page, at: document.pageCount) }
        }
        return document
    }

    @discardableResult
    private func save(close: Bool) async -> Bool {
        guard let file = DocumentFiles.pdf(of: note) else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            try DocumentFiles.save(edited, as: file, of: note, context: context, processing: processing)
            changed = false
            if close { dismiss() }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Saves what was changed, then splits the pages off into new documents and closes.
    private func split(_ split: PDFPages.Split) async {
        if changed, !(await save(close: false)) { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await DocumentFiles.split(note, split, context: context, processing: processing)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A page: its picture (with its rotation) and its number.
private struct PageRow: View {
    let page: PDFPage
    let number: Int
    let version: Int
    @State private var picture: UIImage?

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let picture {
                    Image(uiImage: picture).resizable().scaledToFit()
                } else {
                    Color.primary.opacity(0.06)
                }
            }
            .frame(width: 64, height: 84)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            Text("Page \(number)")
                .font(.body)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .task(id: version) { picture = page.thumbnail(of: CGSize(width: 128, height: 168), for: .mediaBox) }
    }
}
