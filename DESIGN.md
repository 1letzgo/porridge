# Porridge design

The look follows Things 3: quiet white pages, big bold titles, thin lines, and color that says what something is. This file replaces the direction chosen in `design-demos/direction-approved.md` where the app has moved on. iOS, Mac and Android follow the same rules; colors and sizes live in `Porridge/Design/Theme.swift` and `android/.../ui/Theme.kt`.

## Color

| Color | Value | Used for |
| --- | --- | --- |
| Sky | `#24B4E9`, text `#0B79A8` | The plus button, selection, toggles, the mic button, notes and their date headers |
| Navy | `#1F3667`, dark `#B0C4EC` | Titles of notes, icons on bars and buttons, symbols on sky, orange and green, meetings, Archive, pins |
| Green | `#29BD80`, text `#0F8A5A` | To-dos and their box, check boxes in summaries |
| Violet | `#7C5CD6`, dark `#9B82E8` | Buckets (projects in the code) |
| Orange | `#FA8F24`, text `#B55D00` | Saved links |
| Red | System red, text `#D93025`, dark `#FF6B60` | Recently Deleted, everything that deletes, recording (the stop button and the mic while it runs), and the due day of an open to-do that is late |

Speakers have their own sequence of colors (`speakerColors`), starting with sky and orange. It says who is talking and nothing about the kind of thing.

Every kind of thing keeps its color everywhere: in the list icon, its section header and its page.

Sky, orange and green are for surfaces. As text or a symbol on a white page they use the darker "text" value, which reaches 4.5:1 (green 3:1, used only bold). Symbols on a full fill of them are navy, never white. In dark mode the bright values are the readable ones. The Apple platforms also have a variant for Increase Contrast.

## Layout

- **Pages** are white (near black in dark mode) with hairlines as separators. Note pages scroll as a whole, head included, on iPhone and Android. The Mac keeps the head of a note in place.
- **Moving between pages:** on iPhone, iPad and Android pages slide in and out as the system does it, and going back follows the finger where the platform offers that. The Mac sidebar changes in place.
- **Section headers** are small and bold in the color of their kind, with a line below. Archive and Recently Deleted are tappable headers with a chevron at the bottom of the home list.
- **Bottom bar:** chat and search as white round buttons with navy icons on the left, the blue plus on the right. Each opens a page of its own: the search with its field on top, the chat with its field at the bottom.
- **Chat:** a page of its own that asks the buckets, with its field at the bottom instead of the round buttons. A chat is about all buckets or one (a pill on top says which; a new chat can choose), answers name the notes they come from as pills, and chats are kept: the bar of the page has the list of chats and a new chat.
- **Plus menu:** what can be created (Bucket, Link, Meeting, To-do, Note), each in the color of its kind.
- **Import menu:** a button in the bar beside Settings, on the home list and in a bucket: Import Audio, Import Plaud once signed in, Photo or File.
- **Live Activity and notification:** the running meeting with its clock, pause and stop. Navy on the light Lock Screen card, white on the black Dynamic Island.
- **Inbox:** rows like in every list. A bucket is chosen in the long press of a row; only a suggested bucket shows as a pill under it.
- **Home list:** the Inbox with one entry of its name, then the buckets: the pinned ones and the 5 latest others; "More" unfolds the rest in place.
- **Row icons:** a rounded square as high as the two lines of the row, in the color of the kind, with the kind's symbol (`Note.kindSymbol`): to-do `checklist` (green), meeting `waveform` (navy), note `text.alignleft` or `paperclip` with a file (sky), link `link` (orange), image `photo`, PDF `doc.richtext`, file `doc` (navy). The same symbol names the kind in the plus menu, the bar of its page and the pills that point to a note (the source of a to-do, the sources of a chat answer). A pinned entry wears a small navy pin badge on the top right of the icon's border.
- **Kinds:** to-dos, meetings, notes, links, images and files. Images and files are two kinds that behave alike. A bucket's filter pills show only the kinds it holds.
- **Check boxes:** green squares for to-dos and for tasks inside summaries. Circles only for checklists you write in a note (the subtasks of a to-do are such a checklist).

## Controls

- **Sheets:** "Cancel" on the left when closing throws work away, "Done" on the right when nothing is lost.
- **Deleting for good always asks first.** Moving something to Recently Deleted does not, because it can come back.
- **Main buttons** are a wash of their color with a navy label. Disabled buttons fade; destructive ones turn red.
- **Summary models** are one list, on-device and cloud alike, with one default. Adding one happens in a sheet; a meeting chooses its model and template in one sheet, and that choice holds for this summary only.
- **Menus** are grouped by a line: the note and its summary, the recording, what deletes.
- **Native controls first.** Custom ones only where the system has no equivalent.
- **Wording:** English Title Case for buttons and titles, "…" without a space before it.

## To-dos

A to-do is a note like any other, not a list of its own: it lives in the timeline, the Inbox, buckets, the archive, Recently Deleted, the search, the chat, the sync and the export the same way. What makes it a to-do is a done state; its subtasks are the checklist lines of its text. (The to-dos removed in 1.1 were items of their own with a tab of their own; that parallel world does not come back.)

**Using them**

- **Creating:** "To-do" in the plus menu makes a new note that is a to-do, the same way as "Note" (in a bucket it goes into it). Any note that is no meeting and no saved link or file can be turned into a to-do and back: "Convert to To-do" / "Convert to Note" in the note's More menu and in the long press of its row. The text stays as it is.
- **Icon and box:** a to-do has the icon of its kind like every entry (green rounded square, `checklist`; Material `checklist` on Android), the same whether it is open, done or late: the state is the box's and the due day's, not the icon's. The box that ticks it is a separate control at the end of the row, 26 pt drawn and 44 pt to tap: open a green outline with a light green wash, done filled green with a navy `checkmark`. On its page the same box stands before the title. Icon and box are apart because the icon of every other kind opens the entry rather than changing it, and an empty box at the start of a row read as a missing icon.
- **Row:** tapping the box ticks the to-do right in the list. A done one is struck through and grey. The row's preview shows the open subtasks (joined by " · "), its footer the progress "2/5" with a `checkmark.circle` symbol, like the circles of the subtasks (green once all are done). Swipe from the left and the long press have "Mark as Done" / "Mark as Not Done".
- **Page:** the box stands before the title; the bar says "To-do" in green. The meta line adds "Done …" and "2 of 5 done". The body is the normal editor; its circles are the subtasks: tap to tick, Return for the next, Tab to indent, the format menu moves a line up or down ("Move Line Up/Down", ⌥⌘↑/↓ on a keyboard), deleting the line deletes the subtask. "Add Subtask" below the text adds an empty one at the end with the cursor in it.
- **Done:** a done to-do stays where it is, ticked and grey, for the rest of the day. From the next day on it counts as archived: out of the Inbox and the buckets, in the Archive and the search. Taking it out of the archive ("Mark as Not Done") opens it again. Archiving by hand works as for every note.
- **Due day:** a to-do can be due on a day (no time of day). Its page has a chip first in the row of buckets and tags: "+ Due Date" while there is none, otherwise the day ("Today", "Fri", "12 Dec") in green, or in red when it is late. The chip is a menu: Today, Tomorrow, Next Week (the first day of next week, as the calendar counts weeks), Pick Date… (the system's calendar in a sheet), and Clear Due Date. The long press of a list row has the same menu ("Due Date"). A new to-do sets it the same way, right on its page. In the row the day stands in the footer with a calendar symbol: red and semibold when an open to-do is late (from midnight after the day, with a calendar symbol with an exclamation mark), green and semibold when it is due today, grey otherwise; a done to-do is never marked. "Make To-do" from a summary sets no day. There are no reminders or notifications and nothing goes to a calendar.
- **Filter:** the search has the chip "Open To-dos" (to-dos not done and not archived), grouped by due day: Overdue, Today, Upcoming, No Due Date (empty groups left out), each by due day. A bucket has the filter pill "To-dos" and the section "To-dos" first: open ones by due day (earliest first, those without one after them), then those done today; its row counts "Open To-dos". Everywhere else the timeline stays as it is.
- **From a summary:** every task line (`- [ ]`) of a summary has a small button "Make To-do" (and the same in its long press). It makes a new open to-do titled with the task, in the same buckets as the note, pointing back to it; the to-do's page shows the note as a pill that opens it. Nothing is made by itself, and saved links and files offer nothing. A task already taken over shows a green double square instead of the button.

**Format** (iOS is the source; Android mirrors it exactly)

- Three fields of `Note` (Room: `NoteEntity`), all optional, nil/absent by default:
  - `todoStateRaw: String?` — `"open"`, `"done"`, or `"none"` for a to-do turned back into a note. Absent (nil) = the note never was a to-do. `isTodo` = open or done; `isDone` = done.
  - `todoDoneAt: Date?` — when it was ticked; nil while open.
  - `todoSourceID: String?` — the `id` (uppercase UUID) of the note whose summary task it came from.
  - `todoDueDay: String?` — the due day as `"yyyy-MM-dd"` (zero-padded, Gregorian): a day of the calendar, no time, no time zone, so it is the same day on every device wherever it is. `"none"` = a due day was taken away. Nil = never set. It counts only while the note is a to-do (`todoDue`); a note turned back keeps it stored and does not show it. Anything that is not ten characters of three numbers counts as no due day.
- **Sync record** (`notes` in the sync file): the same names. `todoStateRaw` string, `todoDoneAt` milliseconds since 1970, `todoSourceID` string. A field is left out when nil, so the records of all other notes (and their hashes) stay as they were.
- **Applying a record:** only when it has `todoStateRaw` are the three fields `todoStateRaw`, `todoDoneAt`, `todoSourceID` taken from it (missing `todoDoneAt`/`todoSourceID` then mean nil). `todoDueDay` on its own: taken when the record has it (a string, `"none"` included), kept as it is when it has not. So clearing writes `"none"` (only when there was a value; clearing a never set day writes nothing), and a version that knows no due days cannot lose or erase one. When both devices changed the note, the newer record wins as for every field. A record without `todoStateRaw` comes from a version that knows no to-dos (or the note never was one): the device keeps its own three fields. That is why turning a to-do back writes `"none"` instead of removing the field.
- **Subtasks:** lines matching `^([ \t]*)[-*+][ \t]+\[([ xX])\](?:[ \t]+(.*))?$` (the editor's checklist syntax), outside ```` ``` ```` code blocks, with non-empty text after trimming. Ticked = `x` or `X`. Indent = (spaces + 2 per tab) / 2. The app writes `- [ ] ` and `- [x] `, two spaces per indent level. Progress = ticked / all; "complete" needs at least one subtask.
- **Done rules** (on a change of the subtasks from old to new text, `Todos.stateAfterEdit`): open and the new text complete while the old was not → done (`todoDoneAt` = now). Done and the new text has an open subtask while the old had none, or fewer are ticked than before → open (`todoDoneAt` = nil). Nothing else changes the state: reopening a to-do by hand leaves its subtasks ticked and it stays open. Ticking the to-do itself ticks all its subtasks; unticking it leaves them.
- **Due day rules:** today = the device's current day in its time zone, as `"yyyy-MM-dd"`. Keys compare as strings. Overdue = open to-do and due day < today. Due today = due day == today. Labels (`Todos.dueLabel`): days from today 0 "Today", 1 "Tomorrow", -1 "Yesterday", 2 to 6 the abbreviated weekday (template `EEE`), otherwise day and abbreviated month (template `dMMM`) in this year, with the year (template `dMMMy`) in another; formatted in the device's locale. Sorting (`Todos.byDue`): open to-dos by due day ascending, those without a due day after them in their previous order, then the done ones. Groups (`Todos.dueGroups`): Overdue, Today, Upcoming, No Due Date.
- **Put away:** `isArchived` = `archivedAt != nil` or (done and `todoDoneAt` before the start of today, local time). `isInInbox` uses `isArchived`. "Unarchive" of such a to-do sets it open (and `archivedAt` nil).
- **Merge of ticks** (`SyncMerge`, `Todos.mergeRecords`): the sync base of a to-do record also keeps its `text` as last written to the file (`SyncBase.text`, only for records whose `todoStateRaw` is open or done). When both sides changed a to-do, the newer record wins as for every note, but the subtasks the other side ticked or unticked since the base text are applied to it, as long as the newer one left that subtask alone. Subtasks are matched by their lowercased text and how many lines with the same text came before. If that changed the newer text, the done rules above run on it (from the newer text to the merged one, done time = the merge time) and the result is applied on this device and written to the file. Without a base text the newer record wins unchanged.
- **Chat:** a to-do adds one passage to the chat index before its summary and text: `To-do, open: <title>` or `To-do, done on <day month year>: <title>`; with a due day `, due <d MMMM yyyy in English, e.g. 12 December 2026>` follows the state, and `, overdue` after it when it is open and late; then `, <n> of <m> subtasks done` when it has subtasks, then the colon and the title (`ChatRetrieval.todoLine`). The passage is dated by the start of its due day (other passages by the note's creation), so a question about a time ("this week") finds what is due then. The index hash of a to-do includes `todoStateRaw`, `todoDueDay`, `todoDoneAt` and whether it is overdue, so the passage is cut again when one of them changes (also at midnight).
- **Export:** `exportText` adds the line `[ ] To-do` or `[x] To-do, done` after the head, with `, due <d MMMM yyyy>` when it has a due day.
