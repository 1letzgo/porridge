import AppKit

/// Naming a speaker, in the inspector's Speakers and on a name in the transcript (as on the iPhone): the people
/// invited to the appointment, the user, another name; on a line of the transcript also giving only that line to
/// another speaker; the known voices.
@MainActor
enum SpeakerMenu {
    static func make(for speaker: Speaker, in note: Note, segment: TranscriptSegment? = nil, window: NSWindow?) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: String(localized: "\(speaker.name) is…")))
        let choices = SpeakerNaming.choices(for: speaker.id, in: note)
        for name in choices {
            let item = menu.add(name) { rename(speaker.id, to: name, in: note) }
            item.subtitle = String(localized: "Invited")
        }
        if let me = AppSettings.myName, !AppSettings.isMe(speaker), !choices.contains(me) {
            menu.add(String(localized: "\(me) (Me)")) { rename(speaker.id, to: me, in: note) }
        }
        menu.add(String(localized: "Other Name…"), symbol: "pencil") {
            Alerts.ask("Rename Speaker", placeholder: "Name", value: speaker.name, action: "Save", in: window) { text in
                rename(speaker.id, to: text, in: note)
            }
        }
        if let segment {
            let others = note.speakers.filter { $0.id != segment.speakerId }
            if !others.isEmpty {
                let line = NSMenu()
                for other in others {
                    line.add(other.name) { reassign(segment, to: other, in: note) }
                }
                let item = NSMenuItem(title: String(localized: "Only This Line"), action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: "text.line.first.and.arrowtriangle.forward", accessibilityDescription: nil)
                item.submenu = line
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.add(String(localized: "Known Voices…"), symbol: "person.wave.2") { showKnownVoices(in: window) }
        return menu
    }

    static func showKnownVoices(in window: NSWindow?) {
        guard let content = window?.contentViewController else { return }
        content.presentAsSheet(VoicesSheetController())
    }

    /// Also teaches the voice under this name, checks earlier unnamed speakers against it and writes the summary
    /// again with it (`SpeakerNaming.rename`).
    private static func rename(_ id: String, to name: String, in note: Note) {
        let library = Library.shared
        SpeakerNaming.rename(id, to: name, in: note, context: library.context, processing: library.processing)
        library.setNeedsReload()
    }

    private static func reassign(_ segment: TranscriptSegment, to speaker: Speaker, in note: Note) {
        note.segments = note.segments.map { item in
            var item = item
            if item.id == segment.id { item.speakerId = speaker.id }
            return item
        }
        Library.shared.save()
    }
}
