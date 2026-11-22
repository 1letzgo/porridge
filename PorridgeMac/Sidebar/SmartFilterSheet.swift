import AppKit

/// Creates, changes, renames and deletes smart filters on the Mac: a sheet on the window with every criterion and how
/// many entries fit right now. Only the saved search changes: entries are never moved.
@MainActor
enum SmartFilterSheet {
    /// A new filter from what was searched for; `then` gets it once it is saved.
    static func create(_ criteria: SmartFilterCriteria, in window: NSWindow?, then: @escaping (SmartFilter) -> Void = { _ in }) {
        show(title: String(localized: "New Smart Filter"), name: "", criteria: criteria, action: String(localized: "Save"), in: window) { name, criteria in
            then(SmartFilterStore.shared.add(name: name, criteria: criteria))
        }
    }

    static func edit(_ filter: SmartFilter, in window: NSWindow?) {
        show(title: String(localized: "Edit Smart Filter"), name: filter.name, criteria: filter.criteria, action: String(localized: "Save"), in: window) { name, criteria in
            SmartFilterStore.shared.update(filter.id, name: name, criteria: criteria)
        }
    }

    static func rename(_ filter: SmartFilter, in window: NSWindow?) {
        Alerts.ask(String(localized: "Rename Smart Filter"), placeholder: String(localized: "Name"), value: filter.name, action: String(localized: "Rename"), in: window) { name in
            SmartFilterStore.shared.rename(filter.id, to: name)
        }
    }

    static func confirmDelete(_ filter: SmartFilter, state: WindowState, in window: NSWindow?) {
        Alerts.confirm(
            "Delete “\(filter.name)”?", message: String(localized: "Only the saved search is deleted. The entries stay where they are."),
            action: String(localized: "Delete Smart Filter"), in: window
        ) {
            if state.page == .smartFilter(filter.id) { state.page = .inbox }
            SmartFilterStore.shared.delete(filter.id)
        }
    }

    private static func show(
        title: String, name: String, criteria: SmartFilterCriteria, action: String, in window: NSWindow?,
        save: @escaping (String, SmartFilterCriteria) -> Void
    ) {
        let form = Form(name: name, criteria: criteria)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(localized: "Lists every entry that fits, wherever it is. Nothing is moved: entries stay in their bowl or the Inbox.")
        alert.accessoryView = form.grid
        let ok = alert.addButton(withTitle: action)
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        form.saveButton = ok
        form.update()
        alert.window.initialFirstResponder = form.name
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let criteria = form.criteria
            let typed = form.name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            save(typed.isEmpty ? SmartFilters.suggestedName(for: criteria, bowlName: form.bowlName) : typed, criteria)
        }
        if let window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// The controls of the sheet; recounts the entries that fit on every change.
    @MainActor
    private final class Form: NSObject, NSTextFieldDelegate {
        let name = NSTextField(string: "")
        let words = NSTextField(string: "")
        let tags = NSTextField(string: "")
        let kind = NSPopUpButton(frame: .zero, pullsDown: false)
        let source = NSPopUpButton(frame: .zero, pullsDown: false)
        let documentKind = NSPopUpButton(frame: .zero, pullsDown: false)
        let sender = NSTextField(string: "")
        let dateMode = NSPopUpButton(frame: .zero, pullsDown: false)
        let year = NSPopUpButton(frame: .zero, pullsDown: false)
        let hasFrom = NSButton(checkboxWithTitle: String(localized: "From"), target: nil, action: nil)
        let from = NSDatePicker()
        let hasTo = NSButton(checkboxWithTitle: String(localized: "To"), target: nil, action: nil)
        let to = NSDatePicker()
        let bowl = NSPopUpButton(frame: .zero, pullsDown: false)
        let count = NSTextField(labelWithString: "")
        var grid: NSGridView!
        weak var saveButton: NSButton?
        private let library = Library.shared

        init(name value: String, criteria: SmartFilterCriteria) {
            super.init()
            name.stringValue = value
            name.placeholderString = SmartFilters.suggestedName(for: criteria)
            words.stringValue = criteria.text
            words.placeholderString = String(localized: "Words in the entry")
            tags.stringValue = criteria.tags.joined(separator: ", ")
            tags.placeholderString = String(localized: "Tags, separated by commas")
            sender.stringValue = criteria.sender ?? ""
            sender.placeholderString = String(localized: "Sender of a document")
            for field in [name, words, tags, sender] {
                field.delegate = self
                field.widthAnchor.constraint(equalToConstant: 260).isActive = true
            }

            fill(kind, SmartFilterKind.allCases.map { ($0.title, $0.rawValue) }, selected: criteria.kind)
            fill(source, SmartFilters.sources.map { ($0.label, $0.rawValue) }, selected: criteria.source)
            fill(documentKind, DocumentKind.allCases.map { ($0.title, $0.rawValue) }, selected: criteria.documentKind)
            var bowls = library.activeProjects.map { ($0.name, Projects.key($0)) }
            if let chosen = criteria.bowl, chosen != SmartFilterCriteria.inbox, !bowls.contains(where: { $0.1 == chosen }) {
                bowls.append((bowlName(chosen) ?? String(localized: "Deleted Bowl"), chosen))
            }
            fill(bowl, [(String(localized: "Inbox"), SmartFilterCriteria.inbox)] + bowls, selected: criteria.bowl)

            dateMode.addItems(withTitles: [String(localized: "Any Time"), String(localized: "Year"), String(localized: "Range")])
            let now = Calendar.current.component(.year, from: Date())
            var years = Array((now - 15)...(now + 1)).reversed().map { $0 }
            if let whole = criteria.wholeYear, !years.contains(whole) { years.append(whole) }
            year.addItems(withTitles: years.map(String.init))
            year.selectItem(withTitle: String(criteria.wholeYear ?? now))
            for picker in [from, to] {
                picker.datePickerStyle = .textFieldAndStepper
                picker.datePickerElements = .yearMonthDay
                picker.dateValue = Date()
            }
            if criteria.wholeYear != nil {
                dateMode.selectItem(at: 1)
            } else if criteria.from != nil || criteria.to != nil {
                dateMode.selectItem(at: 2)
                hasFrom.state = criteria.from == nil ? .off : .on
                hasTo.state = criteria.to == nil ? .off : .on
                from.dateValue = DocumentInfo.date(fromDay: criteria.from) ?? Date()
                to.dateValue = DocumentInfo.date(fromDay: criteria.to) ?? Date()
            }
            for control in [kind, source, documentKind, dateMode, year, bowl, hasFrom, hasTo, from, to] as [NSControl] {
                control.target = self
                control.action = #selector(changed)
            }
            count.textColor = .secondaryLabelColor

            func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }
            grid = NSGridView(views: [
                [label(String(localized: "Name:")), name],
                [label(String(localized: "Words:")), words],
                [label(String(localized: "Tags:")), tags],
                [label(String(localized: "Kind:")), kind],
                [label(String(localized: "Came In As:")), source],
                [label(String(localized: "Document Kind:")), documentKind],
                [label(String(localized: "Sender:")), sender],
                [label(String(localized: "Date:")), NSStackView.horizontal([dateMode, year], spacing: 6)],
                [NSGridCell.emptyContentView, NSStackView.horizontal([hasFrom, from], spacing: 6)],
                [NSGridCell.emptyContentView, NSStackView.horizontal([hasTo, to], spacing: 6)],
                [label(String(localized: "Bowl:")), bowl],
                [NSGridCell.emptyContentView, count],
            ])
            grid.column(at: 0).xPlacement = .trailing
            grid.rowAlignment = .firstBaseline
            grid.rowSpacing = 8
            grid.columnSpacing = 8
            grid.frame = NSRect(x: 0, y: 0, width: 400, height: grid.fittingSize.height)
            update()
        }

        private func fill(_ popup: NSPopUpButton, _ options: [(String, String)], selected: String?) {
            popup.addItem(withTitle: String(localized: "Any"))
            for (title, value) in options {
                popup.addItem(withTitle: title)
                popup.lastItem?.representedObject = value
                if value == selected { popup.select(popup.lastItem) }
            }
        }

        private func value(_ popup: NSPopUpButton) -> String? {
            popup.selectedItem?.representedObject as? String
        }

        func bowlName(_ key: String) -> String? {
            library.projects.first { Projects.key($0) == key }?.name
        }

        var criteria: SmartFilterCriteria {
            var result = SmartFilterCriteria()
            result.text = words.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            result.tags = tags.stringValue.split(whereSeparator: { $0 == "," || $0 == " " }).map { Note.cleanTag(String($0)) }.filter { !$0.isEmpty }
            result.kind = value(kind)
            result.source = value(source)
            result.documentKind = value(documentKind)
            let typed = sender.stringValue.trimmingCharacters(in: .whitespaces)
            result.sender = typed.isEmpty ? nil : typed
            result.bowl = value(bowl)
            switch dateMode.indexOfSelectedItem {
            case 1:
                if let chosen = year.titleOfSelectedItem, let number = Int(chosen) {
                    result.from = String(format: "%04d-01-01", number)
                    result.to = String(format: "%04d-12-31", number)
                }
            case 2:
                result.from = hasFrom.state == .on ? DocumentInfo.dayKey(from.dateValue) : nil
                result.to = hasTo.state == .on ? DocumentInfo.dayKey(to.dateValue) : nil
            default:
                break
            }
            return result
        }

        @objc func changed() { update() }

        func controlTextDidChange(_ obj: Notification) { update() }

        func update() {
            let mode = dateMode.indexOfSelectedItem
            year.isHidden = mode != 1
            for view in [hasFrom, from, hasTo, to] as [NSControl] { view.isEnabled = mode == 2 }
            from.isEnabled = mode == 2 && hasFrom.state == .on
            to.isEnabled = mode == 2 && hasTo.state == .on
            let current = criteria
            let found = SmartFilters.results(current, in: library.notes).count
            count.stringValue = found == 1 ? String(localized: "1 entry matches") : String(localized: "\(found) entries match")
            name.placeholderString = SmartFilters.suggestedName(for: current, bowlName: bowlName)
            saveButton?.isEnabled = !current.isEmpty
        }
    }
}
