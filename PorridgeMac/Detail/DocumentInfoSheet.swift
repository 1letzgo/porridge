import AppKit

/// Sets what a document is by hand, as a sheet on the window: kind, sender, date and amount. From then on it is
/// kept as set (`Documents.set`).
@MainActor
enum DocumentInfoSheet {
    static let currencies = ["EUR", "USD", "GBP", "CHF"]

    static func edit(_ note: Note, in window: NSWindow?) {
        let info = note.documentInfo ?? DocumentInfo()

        let kind = NSPopUpButton(frame: .zero, pullsDown: false)
        kind.addItem(withTitle: "Not Set")
        for option in DocumentKind.allCases {
            kind.addItem(withTitle: option.title)
            kind.lastItem?.representedObject = option.rawValue
            kind.lastItem?.image = .symbol(option.symbol, size: 12)
        }
        if let current = info.kind, let index = DocumentKind.allCases.firstIndex(of: current) { kind.selectItem(at: index + 1) }

        let sender = NSTextField(string: info.correspondent ?? "")
        sender.placeholderString = "Company, office or person"

        let hasDate = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        hasDate.state = info.date == nil ? .off : .on
        hasDate.setAccessibilityLabel("Has a Date")
        let date = NSDatePicker()
        date.datePickerStyle = .textFieldAndStepper
        date.datePickerElements = .yearMonthDay
        date.dateValue = info.date ?? Date()
        date.isEnabled = info.date != nil
        let toggle = DateToggle(picker: date)
        hasDate.target = toggle
        hasDate.action = #selector(DateToggle.toggled(_:))

        let amount = NSTextField(string: "")
        amount.placeholderString = "0,00"
        let currency = NSPopUpButton(frame: .zero, pullsDown: false)
        currency.addItem(withTitle: "None")
        var codes = currencies
        let parts = DocumentInfo.parts(ofAmount: info.amount)
        if let code = parts?.currency, !codes.contains(code) { codes.append(code) }
        currency.addItems(withTitles: codes)
        if let (value, code) = parts {
            amount.stringValue = value.formatted(.number.precision(.fractionLength(2)).grouping(.never))
            currency.selectItem(withTitle: code ?? "None")
        } else {
            currency.selectItem(withTitle: Locale.current.currency?.identifier ?? "EUR")
        }

        // Payment, for bills (and papers whose kind says nothing): the day to pay by, and paid on a day.
        let hasDue = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        hasDue.state = info.dueDate == nil ? .off : .on
        hasDue.setAccessibilityLabel("Has a Due Date")
        let due = NSDatePicker()
        due.datePickerStyle = .textFieldAndStepper
        due.datePickerElements = .yearMonthDay
        due.dateValue = info.dueDate ?? Date()
        due.isEnabled = info.dueDate != nil
        let dueToggle = DateToggle(picker: due)
        hasDue.target = dueToggle
        hasDue.action = #selector(DateToggle.toggled(_:))

        let isPaid = NSButton(checkboxWithTitle: "Paid on", target: nil, action: nil)
        isPaid.state = info.paid ? .on : .off
        let paidOn = NSDatePicker()
        paidOn.datePickerStyle = .textFieldAndStepper
        paidOn.datePickerElements = .yearMonthDay
        paidOn.dateValue = DocumentInfo.date(fromDay: info.paidDay) ?? Date()
        paidOn.isEnabled = info.paid
        let paidToggle = DateToggle(picker: paidOn)
        isPaid.target = paidToggle
        isPaid.action = #selector(DateToggle.toggled(_:))

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Kind:"), kind],
            [NSTextField(labelWithString: "Sender:"), sender],
            [NSTextField(labelWithString: "Date:"), NSStackView.horizontal([hasDate, date], spacing: 6)],
            [NSTextField(labelWithString: "Amount:"), NSStackView.horizontal([amount, currency], spacing: 6)],
            [NSTextField(labelWithString: "Pay By:"), NSStackView.horizontal([hasDue, due], spacing: 6)],
            [NSTextField(labelWithString: "Payment:"), NSStackView.horizontal([isPaid, paidOn], spacing: 6)],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        sender.widthAnchor.constraint(equalToConstant: 240).isActive = true
        amount.widthAnchor.constraint(equalToConstant: 120).isActive = true
        grid.frame = NSRect(x: 0, y: 0, width: 330, height: grid.fittingSize.height)

        let alert = NSAlert()

        alert.alertStyle = .warning
        alert.messageText = "Document"
        alert.informativeText = "What this document is. Set by hand, it is no longer changed automatically."
        alert.accessoryView = grid
        alert.addButton(withTitle: "Save")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = sender

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            _ = (toggle, dueToggle, paidToggle)
            guard response == .alertFirstButtonReturn, let context = note.modelContext else { return }
            let code = currency.titleOfSelectedItem.flatMap { $0 == "None" ? nil : $0 }
            let typed = amount.stringValue.trimmingCharacters(in: .whitespaces)
            let chosenKind = (kind.selectedItem?.representedObject as? String).flatMap(DocumentKind.init(rawValue:))
            // A kind that is never paid (a contract) has no due day and no paid mark.
            let payable = DocumentInfo(kind: chosenKind).canBePaid
            let paid = payable && isPaid.state == .on
            let edited = DocumentInfo(
                kind: chosenKind,
                day: hasDate.state == .on ? DocumentInfo.dayKey(date.dateValue) : nil,
                correspondent: sender.stringValue,
                // A typo in the amount keeps the one there was.
                amount: typed.isEmpty ? nil : DocumentExtractor.typedAmount(typed, currency: code) ?? info.amount,
                dueDay: payable && hasDue.state == .on ? DocumentInfo.dayKey(due.dateValue) : nil,
                isPaid: paid ? true : nil,
                paidDay: paid ? DocumentInfo.dayKey(paidOn.dateValue) : nil
            )
            Documents.set(edited, on: note, in: context)
        }
        if let window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// Turns the date picker on and off with its box.
    @MainActor
    private final class DateToggle: NSObject {
        let picker: NSDatePicker

        init(picker: NSDatePicker) {
            self.picker = picker
        }

        @objc func toggled(_ sender: NSButton) {
            picker.isEnabled = sender.state == .on
        }
    }
}
