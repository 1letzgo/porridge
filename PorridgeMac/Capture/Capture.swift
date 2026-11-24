import AppKit

/// Bringing things in: recording a meeting (for an appointment or not), continuing a recording, and Plaud.
@MainActor
enum Capture {
    /// Today's appointments in the inspector's Record mode; the recording takes their place there. Asked again
    /// while they show, Record ends (back to Details).
    static func recordMeeting(in controller: MainWindowController) {
        guard !MeetingRecorder.isRecording else {
            MeetingRecorder.reveal()
            return
        }
        let split = controller.split
        if split.recordPaneContent is RecordMeetingViewController {
            split.endRecord()
            return
        }
        let state = controller.state
        let picker = RecordMeetingViewController(onStart: { [weak controller] appointment in
            startRecording(for: appointment, state: state, in: controller)
        }, onCancel: { [weak split] in
            split?.endRecord()
        })
        split.showRecord(picker)
    }

    /// A recorded meeting becomes a note that is transcribed with speakers; it opens in the window it was started from.
    /// For an appointment (from the sheet or the alert before a meeting) the meeting is named after it and remembers
    /// its people for the speakers (`MeetingLinks`).
    static func startRecording(for appointment: CalendarAppointment?, state: WindowState, in controller: MainWindowController? = nil) {
        let project = state.projectForNew
        let title = appointment?.title
        let host = controller ?? MainWindowController.all.first { $0.state === state }
        MeetingRecorder.start(title: title, in: host) { finished in
            addMeeting(finished, title: title, appointment: appointment, project: project, state: state)
        }
    }

    private static func addMeeting(_ finished: MeetingRecorder.Finished, title: String?, appointment: CalendarAppointment? = nil, project: String?, state: WindowState?) {
        let result = finished.result
        let note = Note()
        note.source = .meeting
        note.title = title ?? Note.defaultMeetingTitle(for: note.createdAt)
        note.titleIsCustom = title != nil
        note.statusRaw = ProcessingStatus.recorded.rawValue
        note.audioFileName = result.fileName
        note.duration = result.duration
        note.channelCount = result.channelCount
        note.inputName = result.inputName
        note.text = RecordingNote.markdown(finished.written)
        if result.isSplitStereo {
            note.speakerMode = .channels
            note.speakers = [
                Speaker(id: SpeakerAssigner.leftChannelID, name: finished.speakerNames[0], colorIndex: 0),
                Speaker(id: SpeakerAssigner.rightChannelID, name: finished.speakerNames[1], colorIndex: 1),
            ]
        }
        if !finished.liveText.isEmpty {
            // Shown until the final transcript with speakers is ready.
            note.segments = [TranscriptSegment(speakerId: nil, start: 0, end: result.duration, text: finished.liveText)]
        }
        if let project { note.projectIDs = [project] }
        let library = Library.shared
        if let appointment {
            MeetingLinks.remember(appointment, for: note.id)
            AppointmentLinks.shared.linkMeeting(note, to: appointment, in: library.context)
        }
        library.context.insert(note)
        library.save()
        library.setNeedsReload()
        if let state {
            if state.page == .chat || state.page == .search || !state.page.allowsCreating { state.page = .inbox }
            state.open(note.id)
        }
        library.processing.enqueue(.transcript(note.id))
    }

    /// A part recorded later is added to the meeting and transcribed. The meeting is looked up again at the end:
    /// deleted in the meantime (here or by the sync), the part becomes a meeting of its own instead of being lost.
    static func continueRecording(_ note: Note) {
        let id = note.id
        let title = note.title
        MeetingRecorder.start(title: title, continues: id) { finished in
            let library = Library.shared
            guard let note = library.note(id), note.modelContext != nil, !note.isDeleted else {
                addMeeting(finished, title: title, project: nil, state: MainWindowController.frontIfAny?.state)
                return
            }
            note.addRecordedPart(finished.result.fileName, written: finished.written)
            library.save()
            library.processing.enqueue(.note(id))
        }
    }

    static func importPlaud(in controller: MainWindowController) {
        let state = controller.state
        let sheet = PlaudImportViewController { audio in
            let library = Library.shared
            PlaudImporter.addNote(audio, projectID: state.projectForNew, context: library.context, processing: library.processing)
            library.setNeedsReload()
        }
        controller.window?.contentViewController?.presentAsSheet(sheet)
    }
}
