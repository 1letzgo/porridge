#if DEBUG
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers

/// Data for the UI tests, only in debug builds: `-seedMeetingWithTasks <title>` adds a summarized meeting whose
/// summary has three tasks (the user's, somebody else's with a date, nobody's), in a new bowl of the same name.
/// `-seedTodos <prefix>` adds four open to-dos: "<prefix> long overdue" (due 1 January 2000, in a new bowl named
/// <prefix>), "<prefix> today", "<prefix> upcoming" (in five days) and "<prefix> no date".
enum TestSeed {
    @MainActor
    static func run(_ container: ModelContainer) {
        // `-resetWhatsNew YES`: the What's New card shows again (a launch argument would override what "Got It" sets).
        if UserDefaults.standard.bool(forKey: "resetWhatsNew") { UserDefaults.standard.removeObject(forKey: WhatsNew.seenKey) }
        seedTodos(container)
        if UserDefaults.standard.bool(forKey: "seedEntryKinds") { seedEntryKinds(container.mainContext) }
        // Only on the store in memory: added on every launch, it would pile up in a real one.
        if UserDefaults.standard.bool(forKey: "seedInbox"), UserDefaults.standard.bool(forKey: "emptyStore") { seedInbox(container.mainContext) }
        // `-seedInboxCount <n>` (with `-emptyStore YES`): n plain notes in the Inbox, for a badge with three digits.
        let count = UserDefaults.standard.integer(forKey: "seedInboxCount")
        if count > 0, UserDefaults.standard.bool(forKey: "emptyStore") {
            for index in 1...count {
                let note = Note()
                note.source = .note
                note.title = "Inbox note \(index)"
                container.mainContext.insert(note)
            }
            try? container.mainContext.save()
        }
        guard let title = UserDefaults.standard.string(forKey: "seedMeetingWithTasks"), !title.isEmpty else { return }
        let context = container.mainContext
        // Made again on every launch (the launch argument stays set): what an earlier launch left goes first.
        let earlier = notes(in: context) { $0.title == title && $0.source == .meeting }
        let earlierIDs = Set(earlier.map(\.id.uuidString))
        removeSeeded(earlier + notes(in: context) { $0.todoSourceID.map(earlierIDs.contains) ?? false }, bowlsNamed: [title], in: context)
        let bucket = NoteFolder(name: title)
        context.insert(bucket)
        let meeting = Note()
        meeting.title = title
        meeting.titleIsCustom = true
        meeting.source = .meeting
        meeting.segments = [TranscriptSegment(start: 0, end: 5, text: "Let's wrap up.")]
        meeting.projectIDs = [Projects.key(bucket)]
        meeting.filedAt = Date()
        let due = Todos.dueKey(Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date())
        meeting.summary = """
        ## Summary
        The team planned the launch.

        ## Action Items
        - [ ] Send the offer to the customer – \(AppSettings.myName ?? "Me")
        - [ ] Book the venue – Anna – \(due)
        - [ ] Update the roadmap
        """
        meeting.summaryModel = "Test"
        meeting.summarizedAt = Date()
        TodoSuggestions.offer(meeting)
        context.insert(meeting)
        try? context.save()
        UserDefaults.standard.removeObject(forKey: "seedMeetingWithTasks")
    }

    @MainActor
    private static func seedTodos(_ container: ModelContainer) {
        guard let prefix = UserDefaults.standard.string(forKey: "seedTodos"), !prefix.isEmpty else { return }
        let context = container.mainContext
        // Made again on every launch (a ticked one is open again), never twice: what an earlier launch left goes first.
        let names = ["long overdue", "today", "upcoming", "no date"].map { "\(prefix) \($0)" }
        removeSeeded(notes(in: context) { names.contains($0.title) }, bowlsNamed: [prefix], in: context)
        let bucket = NoteFolder(name: prefix)
        context.insert(bucket)
        let today = Date()
        let soon = Calendar.current.date(byAdding: .day, value: 5, to: today) ?? today
        for (name, due) in [("long overdue", "2000-01-01"), ("today", Todos.dueKey(today)), ("upcoming", Todos.dueKey(soon)), ("no date", nil)] {
            let todo = Note()
            todo.title = "\(prefix) \(name)"
            todo.titleIsCustom = true
            todo.source = .note
            todo.todoState = .open
            todo.todoDueDay = due
            if due == "2000-01-01" {
                todo.projectIDs = [Projects.key(bucket)]
                todo.filedAt = today
            }
            context.insert(todo)
        }
        try? context.save()
    }

    @MainActor
    private static func notes(in context: ModelContext, where wanted: (Note) -> Bool) -> [Note] {
        ((try? context.fetch(FetchDescriptor<Note>())) ?? []).filter(wanted)
    }

    /// Takes away what an earlier launch seeded: the notes, and the bowls of these names once nothing else is in them.
    @MainActor
    private static func removeSeeded(_ old: [Note], bowlsNamed names: [String], in context: ModelContext) {
        old.forEach(context.delete)
        let gone = Set(old.map(\.id))
        let rest = ((try? context.fetch(FetchDescriptor<Note>())) ?? []).filter { !gone.contains($0.id) }
        for bowl in (try? context.fetch(FetchDescriptor<NoteFolder>())) ?? [] where names.contains(bowl.name) {
            let key = Projects.key(bowl)
            if !rest.contains(where: { $0.projectIDs.contains(key) }) { context.delete(bowl) }
        }
        try? context.save()
    }

    /// Fixed ids of `seedEntryKinds`, so `porridge://entry/<id>` opens each one (the Mac debug driver's `open-kind`).
    enum KindID {
        static let meeting = UUID(uuidString: "5EED0000-0000-4000-8000-000000000001")!
        static let todo = UUID(uuidString: "5EED0000-0000-4000-8000-000000000002")!
        static let pdf = UUID(uuidString: "5EED0000-0000-4000-8000-000000000003")!
        static let link = UUID(uuidString: "5EED0000-0000-4000-8000-000000000004")!
        static let note = UUID(uuidString: "5EED0000-0000-4000-8000-000000000005")!
        static let image = UUID(uuidString: "5EED0000-0000-4000-8000-000000000006")!

        static func named(_ name: String) -> UUID? {
            ["meeting": meeting, "todo": todo, "pdf": pdf, "link": link, "note": note, "image": image][name]
        }
    }

    /// One entry of every kind with the values the design's mockups show (`-seedEntryKinds YES`, the Mac debug
    /// driver's `seed-kinds`): a meeting with four speakers (one unnamed) in "Q4 Planning", a to-do with subtasks,
    /// a due day and Weekly in "Kitchen Renovation", an invoice PDF in the Inbox with "House & Bills" suggested, a
    /// link in "Reading", a note in "Berlin Trip" and an image. Added once (by their fixed ids).
    @MainActor
    static func seedEntryKinds(_ context: ModelContext) {
        // Made again on every launch: a test that changed one of them (its bowl, its kind) leaves nothing behind for
        // the next one.
        let seeded: Set<UUID> = [KindID.meeting, KindID.todo, KindID.pdf, KindID.link, KindID.note, KindID.image]
        let existing = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        let old = existing.filter { seeded.contains($0.id) }
        if !old.isEmpty {
            old.forEach(context.delete)
            try? context.save()
        }
        var folders = (try? context.fetch(FetchDescriptor<NoteFolder>())) ?? []
        func bowl(_ name: String) -> String {
            if let found = folders.first(where: { $0.name == name }) { return Projects.key(found) }
            let made = NoteFolder(name: name)
            context.insert(made)
            folders.append(made)
            return Projects.key(made)
        }
        let now = Date()
        func add(_ id: UUID, _ title: String, text: String = "", in bowlName: String? = nil, configure: (Note) -> Void) {
            let note = Note()
            note.id = id
            note.title = title
            note.titleIsCustom = true
            note.text = text
            note.source = .note
            if let bowlName {
                note.projectIDs = [bowl(bowlName)]
                note.filedAt = now
            }
            configure(note)
            context.insert(note)
        }
        add(KindID.meeting, "Design Review", in: "Q4 Planning") { note in
            note.source = .meeting
            note.audioFileName = "design-review.m4a"
            note.duration = 42 * 60
            note.inputName = "MacBook Pro Microphone"
            note.statusRaw = ProcessingStatus.ready.rawValue
            note.speakers = [
                Speaker(id: "1", name: AppSettings.myName ?? "Sam", colorIndex: 0),
                Speaker(id: "2", name: "Ben", colorIndex: 1),
                Speaker(id: "3", name: "Priya", colorIndex: 2),
                Speaker(id: "4", name: "Speaker 4", colorIndex: 3),
            ]
            note.segments = [
                TranscriptSegment(speakerId: "1", start: 12, end: 30, text: "Okay, let’s start with the onboarding. The second page has to go."),
                TranscriptSegment(speakerId: "2", start: 31, end: 64, text: "Agreed. I can move the speech model step into settings."),
                TranscriptSegment(speakerId: "3", start: 65, end: 99, text: "Before Friday I’d like to test it on a real phone."),
                TranscriptSegment(speakerId: "4", start: 100, end: 120, text: "Do we keep the flag for the new Today layout?"),
            ]
            note.summary = "## Decisions\n- Onboarding keeps three pages; the speech-model step moves to settings.\n- Ship the new Today layout behind a flag first."
            note.summaryModel = "Test"
            note.summarizedAt = now
            note.labels = ["design"]
        }
        add(KindID.todo, "Choose worktop colour", text: "- [x] Ask Fliesen Maier for samples\n- [x] Measure the north wall\n- [ ] Compare oak and slate\n- [ ] Decide with Anna", in: "Kitchen Renovation") { note in
            note.todoState = .open
            note.todoDueDay = Todos.dueKey(Calendar.current.date(byAdding: .day, value: 3, to: now) ?? now)
            note.todoRepeat = .weekly
            note.labels = ["home"]
        }
        let bills = bowl("House & Bills")
        add(KindID.pdf, "Invoice INV-2026-1142") { note in
            note.source = .share
            var info = DocumentInfo(kind: .invoice, correspondent: "Telekom Deutschland")
            info.amount = "119.00 EUR"
            info.day = DocumentInfo.dayKey(Calendar.current.date(byAdding: .day, value: -3, to: now) ?? now)
            note.attachments = [Attachment(fileName: "seed-invoice.pdf", name: "Invoice INV-2026-1142.pdf", kindRaw: Attachment.Kind.pdf.rawValue, document: info)]
            SeedFiles.invoice("seed-invoice.pdf", number: "INV-2026-1142", from: "Telekom Deutschland")
            note.pageText = "Telekom bills 119,00 € for the November mobile plan, including a one-off roaming charge of 9,90 €."
            note.summary = "Telekom bills 119,00 € for the November mobile plan, including a one-off roaming charge of 9,90 €."
            note.suggestedProjectIDs = [bills]
            note.labels = ["bills"]
            note.statusRaw = ProcessingStatus.ready.rawValue
        }
        add(KindID.link, "The Case for Slow Software", in: "Reading") { note in
            note.source = .link
            note.url = "https://www.example.com/slow-software"
            note.pageText = "Fast software is not always the goal. Slow, considered tools can be better."
            note.summary = "An essay on why considered, slower tools can serve people better than fast ones."
            note.statusRaw = ProcessingStatus.ready.rawValue
        }
        add(KindID.note, "Packing list & plan", text: "Adapter, chargers\nMuseum tickets\nFlights: outbound Friday 07:15", in: "Berlin Trip") { _ in }
        add(KindID.image, "Whiteboard", in: "Q4 Planning") { note in
            note.source = .share
            note.attachments = [Attachment(fileName: "seed-whiteboard.jpg", name: "IMG_0042.jpg", kindRaw: Attachment.Kind.image.rawValue)]
            SeedFiles.whiteboard("seed-whiteboard.jpg")
            note.pageText = "Roadmap Q1: Login, Payments, Export"
            note.statusRaw = ProcessingStatus.ready.rawValue
        }
        try? context.save()
    }

    /// The Inbox of the design's mockups (`-seedInbox YES` with `-emptyStore YES`; the Mac debug driver's `seed-inbox`
    /// on test data): bowls Reading, House & Bills and Berlin Trip; in the Inbox a link with "Reading" suggested, two
    /// Telekom invoices (one with "House & Bills" suggested), a receipt, four Berlin entries sharing the tag "berlin"
    /// (three without a suggestion make the bundle card; the flight has "Berlin Trip" suggested), a note and a to-do
    /// without a due day.
    @MainActor
    static func seedInbox(_ context: ModelContext) {
        var keys: [String: String] = [:]
        let existing = (try? context.fetch(FetchDescriptor<NoteFolder>())) ?? []
        for name in ["Reading", "House & Bills", "Berlin Trip"] {
            if let found = existing.first(where: { $0.name == name }) {
                keys[name] = Projects.key(found)
            } else {
                let bowl = NoteFolder(name: name)
                context.insert(bowl)
                keys[name] = Projects.key(bowl)
            }
        }
        let now = Date()
        var minutes = 0
        func add(_ title: String, text: String = "", suggested: String? = nil, tags: [String] = [], configure: (Note) -> Void = { _ in }) {
            let note = Note()
            note.title = title
            note.titleIsCustom = true
            note.text = text
            note.source = .note
            // The first one is the newest.
            note.createdAt = now.addingTimeInterval(TimeInterval(-60 * minutes))
            note.updatedAt = note.createdAt
            minutes += 37
            note.suggestedProjectIDs = suggested.flatMap { keys[$0] }.map { [$0] } ?? []
            note.labels = tags
            note.statusRaw = ProcessingStatus.ready.rawValue
            configure(note)
            context.insert(note)
        }
        func invoice(_ number: String, days: Int) -> (Note) -> Void {
            { note in
                note.source = .share
                var info = DocumentInfo(kind: .invoice, correspondent: "Telekom")
                info.amount = "119.00 EUR"
                info.day = DocumentInfo.dayKey(Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now)
                note.attachments = [Attachment(fileName: "seed-\(number).pdf", name: "Invoice \(number).pdf", kindRaw: Attachment.Kind.pdf.rawValue, document: info)]
                SeedFiles.invoice("seed-\(number).pdf", number: number, from: "Telekom")
                note.pageText = "Telekom bills 119,00 € for the mobile plan."
            }
        }
        add("The Case for Slow Software", suggested: "Reading") { note in
            note.source = .link
            note.url = "https://example.com/slow-software"
            note.pageText = "Fast software is not always the goal. Slow, considered tools can be better."
            note.summary = "An essay on why considered, slower tools can serve people better than fast ones."
        }
        add("Invoice INV-2026-1142", suggested: "House & Bills", configure: invoice("INV-2026-1142", days: 1))
        add("Your flight LH 2041 is confirmed", text: "Lufthansa · Friday 07:15 Munich – Berlin", suggested: "Berlin Trip", tags: ["berlin"])
        add("Hotel near Hackescher Markt", text: "Two nights, breakfast included.", tags: ["berlin"])
        add("Museum tickets", text: "Pergamon, Saturday 10:00", tags: ["berlin"])
        add("Restaurants to try", text: "Lode & Stijn, Cookies Cream", tags: ["berlin"])
        add("Invoice INV-2026-1098", configure: invoice("INV-2026-1098", days: 30))
        add("Receipt, hardware store") { note in
            note.source = .share
            var info = DocumentInfo(kind: .receipt, correspondent: "Bauhaus")
            info.amount = "46.80 EUR"
            note.attachments = [Attachment(fileName: "seed-receipt.jpg", name: "Receipt.jpg", kindRaw: Attachment.Kind.image.rawValue, document: info)]
            SeedFiles.receipt("seed-receipt.jpg")
        }
        add("Gift ideas for Mum", text: "A good teapot, the new Donna Leon, tulip bulbs")
        add("Call the insurance about the window") { note in
            note.todoState = .open
        }
        try? context.save()
    }

    /// The entries of `ChatDataTests` as real notes, for trying the chat by hand (debug driver `seed-chat` on the
    /// Mac): three bowls "Reisen", "Haus und Garten", "Arbeit" and 15 entries of every kind, dated around Friday,
    /// 20 November 2026. Only on test data (`DataLocation.testFolder`), never in the real store.
    @MainActor
    static func seedChat(_ context: ModelContext) {
        guard DataLocation.testFolder != nil else { return }
        let calendar = Calendar.current
        func day(_ day: Int, month: Int = 11, hour: Int = 10) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
        }
        var keys: [String: String] = [:]
        for name in ["Reisen", "Haus und Garten", "Arbeit"] {
            let bucket = NoteFolder(name: name)
            context.insert(bucket)
            keys[name] = Projects.key(bucket)
        }
        let travel = keys["Reisen"]!, house = keys["Haus und Garten"]!, work = keys["Arbeit"]!
        func add(_ title: String, text: String = "", created: Date, buckets: [String] = [], configure: (Note) -> Void = { _ in }) {
            let note = Note()
            note.title = title
            note.titleIsCustom = true
            note.text = text
            note.createdAt = created
            note.updatedAt = created
            note.projectIDs = buckets
            if !buckets.isEmpty { note.filedAt = created }
            configure(note)
            context.insert(note)
        }
        add("Packliste Norwegen", text: "Regenjacke, Wanderschuhe und Fleece einpacken.", created: day(10), buckets: [travel])
        add("Kickoff Website", created: day(17), buckets: [work]) { note in
            note.source = .meeting
            note.audioFileName = "kickoff.m4a"
            note.speakers = [Speaker(id: "A", name: "Anna", colorIndex: 0), Speaker(id: "B", name: "Ben", colorIndex: 1)]
            note.segments = [
                TranscriptSegment(speakerId: "A", start: 0, end: 5, text: "Wir haben beschlossen, das Budget auf 20.000 Euro festzulegen."),
                TranscriptSegment(speakerId: "B", start: 5, end: 9, text: "Der Launch ist im Februar."),
            ]
            note.summary = "Beschlüsse: Budget 20.000 Euro. Launch im Februar."
            note.statusRaw = ProcessingStatus.ready.rawValue
        }
        add("Weekly", created: day(10), buckets: [work]) { note in
            note.source = .meeting
            note.audioFileName = "weekly.m4a"
            note.segments = [TranscriptSegment(start: 0, end: 5, text: "Die Entscheidung über das Logo verschieben wir.")]
            note.statusRaw = ProcessingStatus.ready.rawValue
        }
        add("Swift Concurrency Guide", created: day(18)) { note in
            note.url = "https://www.swift.org/documentation/concurrency"
            note.pageText = "Swift concurrency uses async and await. Actors protect mutable state."
        }
        add("Sauerteig Rezept", created: day(5), buckets: [house]) { note in
            note.url = "https://example.com/sauerteig"
            note.pageText = "Sauerteig braucht Roggenmehl, Wasser und viel Zeit."
        }
        add("Kotlin Coroutines", created: day(1), buckets: [work]) { note in
            note.url = "https://kotlinlang.org/docs/coroutines-overview.html"
            note.pageText = "Coroutines make asynchronous programming in Kotlin simple."
        }
        add("Angebot an Müller schicken", created: day(1), buckets: [work]) { note in
            note.todoState = .open
            note.todoDueDay = "2026-11-19"
        }
        add("Hecke schneiden", text: "- [x] Schere schärfen\n- [ ] Grünschnitt wegbringen", created: day(12), buckets: [house]) { note in
            note.todoState = .open
            note.todoDueDay = "2026-11-22"
        }
        add("Steuererklärung", created: day(2)) { note in
            note.todoState = .open
            note.todoDueDay = "2026-12-10"
        }
        add("Fahrrad reparieren", text: "Schlauch hinten tauschen.", created: day(3), buckets: [house]) { note in
            note.todoState = .open
        }
        add("Fährtickets buchen", created: day(4), buckets: [travel]) { note in
            note.todoState = .done
            note.todoDueDay = "2026-11-18"
            note.todoDoneAt = day(18, hour: 9)
        }
        add("Whiteboard", created: day(19), buckets: [work]) { note in
            note.source = .share
            note.attachments = [Attachment(fileName: "w.jpg", name: "IMG_0042.jpg", kindRaw: "image")]
            note.pageText = "Roadmap Q1: Login, Payments, Export"
        }
        add("Mietvertrag", created: day(1, month: 10), buckets: [house]) { note in
            note.source = .share
            note.attachments = [Attachment(fileName: "m.pdf", name: "Mietvertrag.pdf", kindRaw: "pdf")]
            note.pageText = "Die Kaution beträgt 2.400 Euro und wird auf ein Sparbuch gezahlt."
        }
        add("Geheimes Projekt", text: "Codename Falke startet im Frühjahr.", created: day(15)) { note in
            note.deletedAt = day(16)
        }
        add("Altes Rezept", text: "Pfannkuchen mit Milch, Mehl und Eiern.", created: day(1, month: 3))
        try? context.save()
    }
}
/// The files the seeded entries point at, drawn here (a one-page invoice PDF, a receipt and a whiteboard photo) and
/// written where the app keeps attachments, so their thumbnails and previews show something instead of a grey blank.
/// Written once; a file that is there stays.
enum SeedFiles {
    private static let ink = CGColor(red: 0.12, green: 0.16, blue: 0.27, alpha: 1)
    private static let grey = CGColor(red: 0.45, green: 0.47, blue: 0.52, alpha: 1)

    static func invoice(_ fileName: String, number: String, from sender: String) {
        guard let url = target(fileName) else { return }
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(box)
        context.setFillColor(CGColor(red: 0.89, green: 0.0, blue: 0.45, alpha: 1))
        context.fill(CGRect(x: 48, y: 760, width: 40, height: 40))
        text(sender, at: CGPoint(x: 100, y: 772), size: 18, bold: true, in: context)
        text("Invoice \(number)", at: CGPoint(x: 48, y: 690), size: 26, bold: true, in: context)
        let rows = [("Mobile plan, November", "109.10 EUR"), ("Roaming, one-off", "9.90 EUR"), ("Total", "119.00 EUR")]
        for (index, row) in rows.enumerated() {
            let y = 620 - CGFloat(index) * 34
            text(row.0, at: CGPoint(x: 48, y: y), size: 14, bold: index == rows.count - 1, in: context)
            text(row.1, at: CGPoint(x: 430, y: y), size: 14, bold: index == rows.count - 1, in: context)
            context.setFillColor(grey)
            context.fill(CGRect(x: 48, y: y - 10, width: 499, height: 0.5))
        }
        text("Please pay within 14 days.", at: CGPoint(x: 48, y: 480), size: 12, color: grey, in: context)
        context.endPDFPage()
        context.closePDF()
    }

    static func receipt(_ fileName: String) {
        image(fileName, width: 600, height: 900, background: CGColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1)) { context in
            text("BAUHAUS", at: CGPoint(x: 60, y: 800), size: 40, bold: true, in: context)
            let rows = [("Screws 4x40", "6.90"), ("Wood glue", "8.40"), ("Sandpaper set", "11.50"), ("Brush 50 mm", "20.00"), ("TOTAL EUR", "46.80")]
            for (index, row) in rows.enumerated() {
                let y = 680 - CGFloat(index) * 60
                text(row.0, at: CGPoint(x: 60, y: y), size: 28, bold: index == rows.count - 1, in: context)
                text(row.1, at: CGPoint(x: 440, y: y), size: 28, bold: index == rows.count - 1, in: context)
            }
        }
    }

    static func whiteboard(_ fileName: String) {
        image(fileName, width: 1200, height: 800, background: CGColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1)) { context in
            text("Roadmap Q1", at: CGPoint(x: 80, y: 660), size: 72, bold: true, in: context)
            let colors = [CGColor(red: 0.85, green: 0.2, blue: 0.2, alpha: 1), CGColor(red: 0.15, green: 0.45, blue: 0.8, alpha: 1), CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1)]
            for (index, word) in ["Login", "Payments", "Export"].enumerated() {
                let x = 80 + CGFloat(index) * 370
                context.setStrokeColor(colors[index])
                context.setLineWidth(8)
                context.stroke(CGRect(x: x, y: 200, width: 320, height: 300))
                text(word, at: CGPoint(x: x + 30, y: 330), size: 52, color: colors[index], in: context)
            }
        }
    }

    // MARK: Drawing

    private static func target(_ fileName: String) -> URL? {
        let url = AudioStore.url(for: fileName, kind: .attachment)
        guard !FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    private static func image(_ fileName: String, width: Int, height: Int, background: CGColor, draw: (CGContext) -> Void) {
        guard let url = target(fileName),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    private static func text(_ string: String, at point: CGPoint, size: CGFloat, bold: Bool = false, color: CGColor? = nil, in context: CGContext) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color ?? ink,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
#endif
