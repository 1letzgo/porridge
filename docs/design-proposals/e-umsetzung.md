# Porridge redesign E ("Three Places + Details"): implementation plan

> **Revision 2 (2026-11-24).** Owner feedback: no two-line header and no user icon. Changes: every iPhone screen keeps
> today's single-line `ChromeBar` (`Porridge/Design/Theme.swift`): back pill, square + title, pills on the right. "+" is
> its last pill (filled). There is no `PlaceHeader`, no subtitle row and no "You" avatar/sheet. Settings opens from a gear
> pill in the Bowls bar (Settings keeps today's General · Recording · AI; Your Name, iCloud Sync, Plaud and About stay in
> General, Known Voices in Recording). Entry pages keep the kind as the bar title. What does not fit in the one row is
> now the first row of the content (Inbox New/Later segment, a bowl's sharing line, "N Selected · Select All").
> Affected: stage 2 (entry bar), stage 4 (iOS part), stage 7 (Settings), the removal list, open questions 1 and 16–17.
> **Stages 0 and 1 are being implemented now; their scope is unchanged.**

Binding spec: `docs/design-proposals/e-drei-orte-details.html` (proposal B "Drei Orte" as the base, with the Details panel
from proposal A; iPhone and Mac built together). This file is the plan for the workers. Code state: commit 5f856d9.

Ground rules for every stage:

- Each stage ends with an app that can go to TestFlight on both platforms. No stage leaves a half-moved feature: when a
  function moves, its old door is removed in the same stage, and its new door exists on both iPhone and Mac.
- Visible text is English, Title Case, "…" without a space. The container is "Bowl" in every visible string.
- **No new CloudKit fields in any stage.** Everything new is either derived from existing `Note` / `NoteFolder` fields,
  stored in `UserDefaults` / scene storage on the device, or in the existing local-only `ChatThread` model. If a worker
  finds they need a synced field, stop and ask (CLAUDE.md: Development schema + deploy to Production first).
- After every stage: `xcodegen generate` if files were added or removed, unit tests green, then `/push-to-phone`
  (owner rule) and run the Mac app. TestFlight only when the owner asks.
- Effort: S = up to a day, M = a few days, L = a week or more (one worker).

---

## Stage overview

| # | Stage | iOS | Mac | Ships as |
|---|---|---|---|---|
| 0 | Shared models and tokens (`EntryDetails`, `EntryMeta`, `EntryMenus`, colours) | S | S | no visible change |
| 1 | One undo | S | S | banners and the chat toast become the one toast |
| 2 | Entry page: quiet head + Details | M | L | new head, Details sheet / inspector (Details \| Record) |
| 3 | Actions by verb, Entry and AI menus | S | M | ✦ AI · Share · ⋯ per kind; Mac menu bar regrouped |
| 4 | Three places (navigation, one-row `ChromeBar` kept) | L | M | tab bar / new sidebar; home, floating buttons, Import menu gone |
| 5 | Search & Ask (search + chat + commands in one field) | L | M | Search tab / toolbar field = ⌘K |
| 6 | Inbox work: swipes, Later, triage, multi-select | M | S | iPhone triage, new selection bar, Mac multi-select inspector |
| 7 | Editor bar, Settings, visual polish, onboarding | M | M | ✦ in editor bars, Settings tidied (Bowls group), tokens applied |

Order rationale: shared models first (testable, invisible); the undo is small and removes four looks before the
screens change; the entry page is where both platforms gain most and it does not depend on the navigation; the
navigation rebuild (largest risk on iOS) then lands on an already quieter entry page; Search & Ask needs the new
navigation (search tab, toolbar field); inbox work and polish come last.

---

## Stage 0 · Shared models and tokens

Goal: one source of truth for what the head shows, what Details shows and what the menus contain, so iPhone and Mac can
never drift. Nothing visible changes.

| | iOS | Mac |
|---|---|---|
| New | `Porridge/Services/EntryDetails.swift`, `EntryMeta.swift`, `EntryMenus.swift` (compiled into both targets: `Porridge/Services` is shared, see `project.yml`) | same files; `PorridgeMac/Support/Brand.swift` gains `brandProjectText`, `toastFill` |
| Assets | `Porridge/Resources/Assets.xcassets`: add `BrandProjectText` (#6A4BC9 / #B5A3F0, HC #5236A8 / #C9BBF5) and `ToastFill` (#1F3667 / #3A4A6E, HC #14264D / #4A5B80) | same catalogue (shared) |
| Theme | `Porridge/Design/Theme.swift`: `Color.brandProjectText`, `Color.toastFill` | — |
| Effort | S | S |

Model sketch (pure Swift, no UI types):

- `EntryDetails.sections(for note: Note, context:) -> [Section]` with `Section` = `.organize`, `.appointment`, `.document`,
  `.speakers`, `.connections`, `.sharingActivity` in this fixed order. Rules: `.document` only when `note.isStored`
  (images, PDFs, files); `.speakers` only when `note.isRecording`; `.organize` rows: type (kind name + to-do switch),
  bowl, due + repeat (only when the entry is a to-do, `Todos`), tags; every row knows if it is locked
  (`note.isDeleted || BowlSharing.shared.isReadOnly(note)`). For several notes: `sections(for notes: [Note])` returns
  only the common fields (bowl, later when all in Inbox, due when all to-dos, document kind/sender/paid when all stored,
  merge when ≥ 2 PDFs, delete) – reuse `Documents.BulkChange`.
- `EntryMeta.items(for note:) -> (facts: String, values: [MetaValue])`: facts = kind · date · duration/pages · source;
  values in order bowl, due, repeat, appointment, document (kind · sender · amount), payment status word, speakers
  count, tags, activity line (`BowlSharing.shared.activityLine`). Never an empty or "+ …" value. Each value carries the
  Details section it opens. A separate `suggestion` (first of `note.suggestedProjectIDs`, only `isInInbox`) for the
  "✦ File into …" pill. The views decide how many fit in two lines and show "+N" for the rest.
- `EntryMenus.ai(for:)`, `.more(for:)`, `.share(for:)` returning ordered item enums (exact contents: HTML section 3.1).
  Hard rules encoded here: links never get `suggestTodos`; Recently Deleted gets only `recover`, `deleteNow`; view-only
  gets `pin`, `copy`, `saveAsTemplate` (+ `askAboutBowl` in AI).

Data impact: none.

Tests (PorridgeTests): `EntryDetailsTests` (section order per kind; document/speakers visibility; due/repeat only for
to-dos; locked in view-only and trash; multi-select common fields), `EntryMetaTests` (only set values, order, overdue
flag, suggestion only in Inbox), `EntryMenusTests` (table 3.1 row by row, links never `suggestTodos`, trash and
view-only menus), `BrandContrastTests` extended for `BrandProjectText` on white/card and `ToastFill` with white text.

Verify on screen: nothing changes (run both apps once).

**As built (stage 0):**

- One input value `EntryContext` (in `EntryDetails.swift`) feeds all three models: bowls (names, suggestion),
  `isReadOnly`, `isInSharedBowl`, `appointment`, `activityLine`, `canUndoEnhance`, `pageCount`, `now`. The apps build it
  with `EntryContext.live(for:bowls:processing:)`; tests build it by hand (view-only, appointments, activity without
  CloudKit or the calendar). Signatures: `EntryDetails.sections(for:context:)`, `EntryMeta.items(for:context:)`,
  `EntryMenus.ai(for:context:)` / `.more(for:context:platform:)` / `.share(for:)`.
- `EntryKind` (note, todo, meeting, link, image, document) is the table's row; a recording that is a to-do stays a
  meeting with Mark as Done added.
- Several notes: `EntryDetails.commonFields(for:)` → `[CommonField]` (bowl, later, due, documentKind, sender(count),
  paid(count, allPaid), mergePDFs(count), delete(count)), not an overload of `sections`.
- `share(for:)` returns one `ShareItem?` (each kind has exactly one share action; nil in Recently Deleted).
- AI and More return groups (`[[Item]]`, one divider between groups); the Mac's Open in New Window is its own group
  before Delete (view-only: last).
- **Convert to To-do deviates from table 3.1:** the code allows to-dos only where `Note.canBeTodo` (not links, stored
  files, shared text or recordings; also enforced by `EntryActions` and chat actions). `EntryMenus` and the Details
  type switch (`EntryDetails.canSwitchTodo`) keep that rule. Question for the owner before stage 3 if the table wins.
- Meta facts keep the date for to-dos too ("To-do · 24 Nov · 1 of 4 subtasks"); pages only when the view passes
  `pageCount`; source word only for link domain, Plaud and imported audio. `VoiceProfiles.isUnnamed` added for
  "N Speakers · 1 unnamed". The bowl value's symbol is the asset image "Bowl" (`EntryMeta.bowlImage`).
- Details rows beyond the plan's list, taken from the mockups: `suggestedBowl` (Inbox), `sameAppointment`, the
  document rows (kind, sender, dated, amount, pay by, paid), `linkedFrom` / `similar`, `sharing` / `activity` /
  `origin`; header actions `changeAppointment`, `editPages` (PDF), `knownVoices`.
- `ToastFill` in Increase Contrast dark (#4A5B80) is lighter than normal dark, so white on it is a little weaker
  (Undo capsule ≈ 4.6:1); the test holds it at ≥ 4.5.

---

## Stage 1 · One undo

Goal: four undo looks become the one toast (`UndoToast` on iOS, `UndoToastPanel` on the Mac).

| | iOS | Mac |
|---|---|---|
| Change | `InboxBundleViews.swift` (bundle undo banner), `SplitNoteSheet.swift` + `NoteDetailView.swift` (`BowlChangeBanner` after split, `enhancedBanner`), `Views/Chat/ChatActionViews.swift` (`ChatUndoToastView`) and `ChatView.swift`: call `UndoToast.shared.offer(…)` instead | `List/InboxBundleBanner.swift` (undo state), `Detail/NoteDetailViewController.swift` (split / enhance banners), `Chat/ChatActionCardsView.swift` + `ChatViewController.swift` (chat toast) → `UndoToast` (the Mac panel already listens to it) |
| Reuse | `Services/UndoToast.swift` (`offer`, `hold`), `UndoToastView` | `Support/UndoToastPanel.swift` |
| New | `UndoToastView` fill = `Color.toastFill`; chat "Confirm All" offers one undo for all confirmed changes | "Delete Chat" asks first and offers undo (`ChatListViewController`) |
| Remove | `BowlChangeBanner`, `enhancedBanner`, `ChatUndoToastView` | the inline undo states of the bundle banner, split, enhance; the chat's own toast |
| Effort | S | S |

Data impact: none (undo closures already exist in `BowlMaking.undo`, `ProcessingService.canUndoEnhance`, `ChatActions`).

Tests: extend the existing undo / chat action tests so that confirming chat actions, splitting and bundling each leave
exactly one `UndoToast.Offer` whose undo restores the state (`ChatActionsTests`, `UXFeaturesTests`).

Verify on screen: bundle a group, split a note, enhance a note, confirm chat actions, delete a chat on the Mac – each
time the same navy toast, Undo works, ⌘Z works on the Mac.

**As built (stage 1):**

- Shared entry points: `BowlMaking.offerUndo(_:in:toast:)` (bundle and split, iOS and Mac),
  `ProcessingService.enhanced(_:original:toast:)` (called when an enhance job finishes, so the toast comes wherever the
  user is by then), `ChatService.confirm(…, toast:)` (one offer for all changes confirmed together, "N changes made"),
  `ChatDeletion.delete(_:in:toast:)` (thread and entries come back with their ids, so the chat's action states stay).
- Typing still on its way is handed over before the toast undoes an enhance: the toast posts
  `ProcessingService.willUndoEnhance`; `NoteDetailView` (`commitTyping`) and `NoteDetailViewController` (`editor.flush`)
  listen. The "Undo Enhance" menu items stay until stage 3 moves them to ✦ AI.
- Removed: `BowlChangeBanner`, the iOS `enhancedBanner`, `ChatUndoToastView`, `ChatService.toast` / `undoToast` /
  `ChatUndoToast` (its message is now `ChatUndoMessage.text`), the Mac `ChatUndoToastBar`, the detail's
  `enhancedBanner` / `splitBanner`, the bundle banner's undo state, `BowlMaking.undoLifetime` (the way back is now the
  toast's 8 s plus ⌘Z on the Mac).
- Look: iOS `UndoToastView` and the Mac `MacUndoToast` are the navy `ToastFill` capsule (white text, "Undo" white on
  16 % white); the Mac keeps its close cross; the Mac panel is 440 × 60 so the shadow is not cut, the capsule sits
  16 pt above the window's bottom edge.
- Delete Chat asks first and offers undo on the Mac only (as planned); the iPhone's chat list still deletes without
  either (shared `ChatDeletion` is ready for stage 5).
- Debug driver (Debug builds only): `toast`, `toast-state`, `shot-toast`, `chat-thread`, `chat-delete`, `chat-count`.

---

## Stage 2 · Entry page: quiet head + Details

Goal: the bar stays today's one-row `ChromeBar` (back pill · kind square + kind name · pills ✦ AI, Share, ⋯ More), then the entry title and one meta line as the first content. Everything editable lives in Details: an
iPhone sheet, the Mac inspector column with two modes Details | Record. Menus keep their current contents in this
stage (stage 3 regroups them), so nothing is lost.

| | iOS | Mac |
|---|---|---|
| Change | `Views/Notes/NoteDetailView.swift`: `header`, `metaLine`, `tagRow` (the chip row), `speakerChips`, the bottom sections; the `ChromeBar` stays as it is (title = kind name, it fits next to three pills: ~96 pt, "Meeting" at ~80 %); `shareAction` / `moreMenu` become the three pills ✦ · Share · ⋯ in stage 3 | `Detail/NoteDetailViewController.swift` (head, chips, bottom sections), `Window/MainSplitViewController.swift` (`MeetingPaneController` → `InspectorController`), `Window/MainWindowController.swift` (toolbar: inspector toggle, `inspectorTrackingSeparator` stays), `Capture/MeetingRecorder.swift` (`host(_:in:)` targets the Record mode), `Capture/RecordMeetingViewController.swift` |
| New | `Views/Notes/EntryHeader.swift` (`MetaLineView` built from `EntryMeta`, wraps to 2 lines, "+N", "ⓘ Details"); `Views/Notes/EntryDetailsSheet.swift` (Form, `.presentationDetents([.medium, .large])`, scroll to a section anchor); transcript speaker name becomes a tap menu (Invited, Me, Other Name…, Only This Line…, Known Voices…) | `Detail/DetailsInspectorViewController.swift` (AppKit form: section headers, label column 84 pt, `NSPopUpButton`s), `MetaLineView` (attributed `NSTextField`, clickable values → inspector anchor); segment Details \| Record at the top of the inspector; View › Details ⌥⌘I, View › Record ⌥⌘R |
| Reuse | `DueDateMenuItems`, `RepeatMenu`, `DueDatePickerSheet` (`TodoViews.swift`), `ProjectMenu` (`ProjectPills.swift`), `AppointmentChip`/`AppointmentPicker`, `AppointmentEntriesSection`, `EntryLinksSection`, `SimilarEntriesSection`, document sheet fields (`Models/DocumentInfo.swift`), `VoicesView` | `DueDateMenu.swift`, `BucketsMenu`, `DocumentInfoSheet.swift` fields, `EntryLinkViews.swift`, `SimilarEntriesView.swift`, `RecordMeetingViewController`, `RecordingViewController`, `PillButton`/`FlowView` (`Controls.swift`) for tags |
| Remove | the chip row (`tagRow`), `speakerChips`, "Changed by" activity line under the title (now a meta value + Details), the bottom sections Linked From / Mentions / Same Appointment / Similar (now Details › Connections) | `NoteChipsView` (entire file), the detail's bottom sections, the single-purpose right column |
| Effort | M | L |

Mac inspector rules (spec, HTML 4): split item `NSSplitViewItem(inspectorWithViewController:)`, 260–400 pt, default 276;
list minimum 290 → 260, detail 380 → 340; window minimum stays 900 × 560. **Sidebar and inspector compete below about
1130 pt**: opening the inspector collapses the sidebar, opening the sidebar collapses the inspector (the last opened
wins); a running recording keeps going and the toolbar counter stays. Implement in `MainSplitViewController`
(observe `splitViewItem.isCollapsed` + window width in `windowDidResize`). Details follows the selection; while
recording, Record mode is not left on selection change. First launch: inspector open when the window is ≥ 1130 pt;
afterwards the split autosave (`PorridgeMainSplit`) keeps the state per window.

Toolbar in this stage: add the inspector toggle and the red recording counter (`NSToolbarItem`, click → Record mode);
keep the rest until stage 3/4.

Data impact: none. "Only This Line…" uses the existing segment reassignment (`reassign(_:to:)`); the to-do switch uses
the existing convert path (`Todos`); paid uses the existing payment fields.

Tests: unit tests from stage 0 cover the content; add `EntryMetaTests` cases for every kind used in the mockups
(meeting, PDF in Inbox, to-do with repeat). UI test: `NotesFlowTests` opens a meeting, opens Details from a meta value
and changes the bowl. Mac: run by hand (no Mac test target).

Verify on screen: meeting, PDF in Inbox, to-do with repeat, link, image, view-only bowl entry, entry in Recently
Deleted – light and dark, Dynamic Type XXXL on iPhone (meta line wraps to two lines, "+N"), iPhone SE width. Mac at
1180, 1130 and 900 pt with the inspector toggled; Record Meeting started from ⌘R, from "Record" at an appointment and
from the meeting alert; recording keeps running when switching to Details and when closing the inspector.

**As built (stage 2):**

- Shared words in `EntryDetails`: `label(_:for:)` (row labels), `typeName(for:)` (the type row names the kind without
  its to-do state: a to-do says "Note" + switch on), `showsTodoSwitch`, `sharingText(for:)` (the bowl's
  `SharedBowlInfo.summary` or "Not shared"), `origin(for:)` ("Recorded · MacBook Pro Microphone · Today 10:00",
  "Came In · By Mail · …" for entries whose text starts with the mail header, "Saved", "Created").
- The bowl value's symbol: the "Bowl" asset is the app's coloured picture (sky square), not a glyph, so both views draw
  the SF Symbol `folder.fill` (the bowl symbol of every menu) in violet. `EntryMeta.bowlImage` is unchanged.
- "Changed by Anna": opening an entry marks it as seen, so the live `activityLine` is nil right after; the head and
  Details use the line as it was at opening (iOS `openedActivity`, Mac `OpenedActivity`).
- Links keep the orange "example.com ↗" line under the title (it is the only visible "open in browser" until stage 3).
- iOS: `EntryHeader.swift` (`EntryMetaLine`, measured with the footnote font of the current Dynamic Type size,
  `WrapLayout`), `EntryDetailsSheet.swift` (Form; sender/dated/amount/pay-by rows open the existing `DocumentInfoSheet`;
  Kind is a menu, Paid a switch, "Clear Document Details" a row; Connections push lists; Known Voices opens
  `KnownVoicesSheet`). Transcript names are menus (`SpeakerMenuItems`): Invited names, "<Your Name> (Me)",
  Other Name…, **Only This Line** as a submenu of the other speakers (no "…": it opens no dialog), Known Voices….
  The long-press "Assign Speaker" stays as a shortcut. `RepeatMenuItems` split out of `RepeatMenu`.
- Mac: `MetaLineView` (an `NSTextView` with link runs; "+N" and values open the inspector; no "Details" word),
  `DetailsInspectorViewController` (also used as a popover for a note in its own window, which has no inspector),
  `InspectorController` (segment Details | Record) and the width rule in `MainSplitViewController`
  (`enforceSharedWidth` on toggle and `windowDidResize`; first launch: open at ≥ 1130 pt, key
  `inspectorFirstLaunchDone`). Toolbar: `.toggleInspector` after the inspector separator, red counter item
  `recording` (hidden unless recording, click = Record). View › Details ⌥⌘I (again: closes), Record ⌥⌘R.
  `MeetingPaneController`, `NoteChipsView` and `DueDateChip` are gone; `FlowView` and `AttachmentStripView` moved to
  `AttachmentStripView.swift`. Speaker naming is `SpeakerMenu` (inspector pills and a click on a transcript name).
  Connections on the Mac are menu values ("1 entry ⌃", "2 · 1 Mention ⌃" with Open / Make the Name a Link).
- Multi-select on the Mac already shows `commonFields` (Bowl, Later, Due, Kind, Set Sender of N…, Mark N as Paid,
  Merge N PDFs…, Delete N) – stage 6 only needs to polish it.
- List rows: suggestion pills clip inside the narrower list (260 pt) instead of pushing the badge past the edge.
- Test seed: `-seedEntryKinds YES` (iOS) / debug driver `seed-kinds` (Mac, test data only) makes one entry of every kind
  with fixed ids; driver commands `open-kind`, `inspector`, `details <section>`, `toggle-sidebar`, `window-width`,
  `layout`, `meta`, `select-many`.

---

## Stage 3 · Actions by verb, Entry and AI menus

Goal: ✦ AI · Share · ⋯ More with the exact per-kind contents of HTML 3.1, built from `EntryMenus`. Mac menu bar: "Note"
becomes "Entry" (15 rows) plus a new "AI" menu; toolbar ⋯ shows the short per-kind More, not the whole menu.

| | iOS | Mac |
|---|---|---|
| Change | `NoteDetailView.swift`: `toolbar`, `shareAction`, `moreMenu` → `aiMenu` + `moreMenu` from `EntryMenus`; Later ▸ in More for Inbox entries (`LaterMenuItems`); "Mark as Paid" in More for payable documents | `App/AppMenu.swift` (`noteMenu(title:)` → `entryMenu()` + `aiMenu()`; File gets Export Bowl…, Export Everything…; Format loses Rewrite (moves to AI, ⌘J kept)); `Detail/NoteCommand.swift` (new cases: later, appointment, document kind/sender/paid, pages, repeat); `MainWindowController.swift` (toolbar: AI pull-down, per-kind ⋯, Share stays `NSSharingServicePickerToolbarItem`; meetings → Export sheet) |
| New | — | Entry › Due Date › Repeat ▸; Entry › Later ▸; Entry › Appointment ▸; Entry › Document ▸; Entry › Pages ▸ (Edit Pages… was context-menu only) |
| Reuse | existing actions in `NoteDetailView` (summarize, enhance, split, suggest, transcribe, continue, merge, copy, templates) | `NoteDetailViewController.perform(_:)` / `validate(_:item:)`, `PDFPageEditorController`, `DocumentInfoSheet`, `DueDateMenu` |
| Remove | the 13-item More menu | the "Note" menu, Export… inside it (File only), the toolbar More = full Note menu |
| Effort | S | M |

Menu bar rule: items that do not apply are disabled in the menu bar, hidden in toolbar menus and context menus.

Data impact: none.

Tests: `EntryMenusTests` (stage 0) is the contract; add a check that every `EntryMenus` item has a handler on iOS
(switch exhaustiveness is enough). Mac: by hand – every Entry/AI item validated for a note, a to-do, a meeting, a link,
an image, a PDF, a trash entry, a view-only entry.

Verify on screen: per kind, the three buttons show exactly table 3.1; ⌘J, ⇧⌘S, ⇧⌘K, ⌃⌘T/M/W/P/⌫ still work; Repeat
reachable from Entry › Due Date.

**As built (stage 3):**

- One contract, two views: iOS `NoteDetailView` (`aiMenu`, `shareAction`, `moreMenu`, `run(_: AIItem)`,
  `run(_: MoreItem)`: exhaustive switches = every item has a handler) and Mac `Detail/EntryToolbarMenu.swift`
  (`aiRow` / `moreRow`, exhaustive; each row sends the same action as its Entry/AI menu row, so it is validated the same
  way; rows keep `EntryMenus`' words, e.g. "Summarize Again…"). `EntryMenus` gained `systemImage`, `isDestructive`,
  `shareFile(for:)` (the local image/PDF for Share, else the text) and `copyText(for:)` (view-only Copy: text, else
  summary, else transcript).
- **Deviation – Suggest To-dos for notes:** a plain note that already has a summary keeps Summarize Again… *and* Suggest
  To-dos in ✦ (both were in the old menus; table 3.1 only lists it for meetings). Links, images, documents and to-dos
  never get it. Convert to To-do follows `Note.canBeTodo` (owner decision): meetings, links, images and documents have none.
- iOS bar: ✦ AI · Share · ⋯ in the `ChromeBar` (and the system toolbar on iPad). ✦ is disabled in Recently Deleted,
  Share there is a disabled pill. Share: meeting → `MeetingExportSheet`, link → its URL, image/document → the file when
  it is on the device. Rewrite Selection… begins `AIRewriteView` for the editor's selection; without one an alert says
  to select text first. Later ▸ is `LaterMenuItems` (+ Back to Inbox Now when snoozed). Scan More Pages opens
  `PDFPageEditor(startsScanning: true)`. Ask About This Bowl closes the entry and opens the chat about its bowl
  (`\.askAboutBowl` environment from `NotesView`). Delete Now… (trash) asks first.
- Mac menu bar: Porridge · File · Edit · Format · View · **Entry** · **AI** · Window · Help.
  Entry: Pin ⇧⌘P · Mark as Done ⇧⌘D (now dimmed, not hidden, for non-to-dos) · Convert to To-do | Bowl ▸ · Due Date ▸
  (Today ⌃⌘T, Tomorrow ⌃⌘M, Next Week ⌃⌘W, Pick Date… ⌃⌘P, **Repeat ▸**, Clear Due Date ⌃⌘⌫) · Later ▸ (choices + Back
  to Inbox Now when snoozed) · Add Tag… ⇧⌘T | Appointment ▸ (Link Appointment ▸ = the appointment list of
  `AppointmentActions.linkMenu`, Remove Appointment) · Document ▸ (Kind ▸, Set Sender…, Mark as Paid/Unpaid, Edit
  Details…) · Recording ▸ (Continue Recording, Transcribe Again, Merge with…, Copy Transcript ⇧⌘C, Delete Recording…) ·
  Pages ▸ (Edit Pages…, Add Pages ▸ From a File…, Merge N PDFs…) · Load Page Again | Dictate ⌥⌘D · Save as Template… |
  Recover (shown only for entries in Recently Deleted) · Delete ⌘⌫ / Delete Now…. Submenu rows are dimmed when nothing
  in them applies (`MainWindowController.entrySubmenu(_:)` + `EntrySubmenu` tags); their contents are filled when they
  open (`DynamicMenu`).
  AI: New Chat ⇧⌘K (moved from File) · Ask About This Bowl | Summarize with AI… ⇧⌘S · Suggest To-dos · Enhance with AI…
  · Undo Enhance · Split into Bowl… · Rewrite with AI… ⌘J (moved from Format) | Summary ▸ (Edit Summary, Insert into
  Note, Copy Summary, Delete Summary…).
  File: Export… ⇧⌘E stays, **Export Bowl…** (open bowl, else the open entry's) and **Export Everything…** added; "Open
  Note in New Window" is now "Open in New Window" ⌘O.
- **Deviations (Mac):** "Link Appointment…" is a submenu with the appointments (no dialog); Add Pages ▸ has only "From a
  File…" (the editor's own Add Pages keeps "From iPhone or iPad", Continuity Camera needs the editor as requestor);
  Recover stays in the Entry menu (hidden unless the selection is in Recently Deleted) since the table had no place for
  it; Mark as Paid / Set Sender / Edit Details / pages commands act on the open entry (multi-select keeps them in the
  inspector and the context menu). Entry › Delete is dimmed for view-only entries (it did nothing before).
- Mac toolbar: new `ai` item (✦ pull-down, inserted before Share into saved configurations), Share is now a plain
  toolbar button (not `NSSharingServicePickerToolbarItem`): it opens `NSSharingServicePicker` with the URL / file /
  text, or the export sheet for a meeting – a picker item cannot open a sheet. ⋯ (`noteMenu` id kept) shows only
  `EntryMenus.more(…, platform: .mac)`. Import and Chat stay in the toolbar until stage 4.
- Where the old menus went:

  | Old item (iPhone More / Mac Note menu) | Now |
  |---|---|
  | Pin, Mark as Done, Convert to To-do/Note | ⋯ More; Mac Entry |
  | Due Date ▸ (Mac) | Entry › Due Date (+ Repeat ▸); Details |
  | Add Tag… (Mac) | Entry; Details |
  | Bowls ▸ (Mac) | Entry › Bowl; Details |
  | Summarize (Again) with AI… | ✦ AI; Mac AI ⇧⌘S |
  | Enhance with AI…, Undo Enhance, Split into Bowl…, Suggest To-dos | ✦ AI; Mac AI |
  | Edit Summary, Insert Summary into Note | summary "…"; Mac AI › Summary |
  | Dictate (Mac) | Entry ⌥⌘D |
  | Continue Recording, Transcribe Again, Merge with…, Copy Transcript, Delete Recording | ⋯ More (meetings); Mac Entry › Recording |
  | Load Page Again | ⋯ More (links); Mac Entry |
  | Edit Pages… | ⋯ More (PDFs); Mac Entry › Pages |
  | Save as Template… | ⋯ More; Mac Entry |
  | Export… / Export (iPhone pill) | Share (meeting → export sheet); Mac File › Export… ⇧⌘E |
  | Copy Summary / Copy Transcript (view-only, iPhone) | ⋯ More › Copy (text, else summary, else transcript); Copy Transcript in Mac Entry › Recording |
  | Recover | ⋯ More (trash); Mac Entry (trash only) |
  | Delete | ⋯ More; Mac Entry ⌘⌫ |
  | Rewrite with AI… (Mac Format) | Mac AI ⌘J; ✦ AI › Rewrite Selection… |
  | New Chat ⇧⌘K (Mac File) | Mac AI |

- Debug driver: `menu-dump <Top>`, `toolbar-menu ai|more`, `toolbar-run ai|more <title>`, `view-only on|off`
  (`BowlSharing.debugReadOnly`, Debug builds only, in memory), `trash-open`, `recover-open`.
- Tests: `EntryMenusTests` (note with summary, to-do never suggests, every kind on the Mac, Share/Copy helpers, symbols);
  UI test `NotesFlowTests.testEntryPillsPerKind` opens ✦ and ⋯ for note, to-do, meeting, link, image and PDF.

---

## Stage 4 · Three places (navigation)

Goal: iPhone tab bar Today · Inbox · Bowls + search tab; Mac sidebar Today ⌘1 · Inbox ⌘2 · Bowls ⌘3 (+ bowls), Smart
Filters, footer Archive ⌘4 · Recently Deleted ⌘5. The old home, the floating buttons and the Import menu disappear.
The search tab in this stage opens today's search page (`SearchPane`) and the chat stays reachable from it via a
"Chat" row; stage 5 merges them.

### iOS

| | |
|---|---|
| Change | `App/RootView.swift` (root becomes `PlacesView`), `Views/Notes/NotesView.swift` (split up: it holds home, routes, sheets and creation; keep the creation/intake actions in a `CaptureActions` helper), `Views/Notes/TodayViews.swift` (`TodayPage`: hint line at the top, Up Next ≤ 5 rows and collapsible, fixed rows Open To-dos and Weekly Review, other days without them), `Views/Projects/ProjectsPane.swift` (`ProjectPage`: bar = back · square + name · ⋯ bowl menu (Select Entries, Pin, Rename…, Ask About This Bowl, Manage Sharing…, Copy Link, Export Bowl…, Archive, Stop Sharing…, Delete Bowl…) · "+"; Select, Share and Import leave the bar; the existing sharing line under the bar becomes the first content row and opens Manage Sharing; `ProjectRow` swipe Pin / Archive / Delete), `Views/Notes/SmartFilterViews.swift` (section in Bowls with "New Smart Filter…"), `Views/Notes/LaterViews.swift`, `Services/HomeList.swift` (no limit; same order for iOS and Mac), `Services/DailyHint.swift` (shown in Today), `Shared/QuickActions.swift` + `Shared/EntryLinkRouter.swift` (`porridge://today`, `porridge://bowls`; `todos` opens Today › Open To-dos), `App/PorridgeShortcuts.swift` / `PorridgeIntents.swift` (Open Today, Open Bowls), widgets' tap targets (`PorridgeWidgets`, `Shared/WidgetData.swift`) |
| New | `Views/Places/PlacesView.swift` (`TabView` with `Tab("Today")`, `Tab("Inbox")`, `Tab("Bowls")`, `Tab(role: .search)`; one `NavigationStack` per tab; badges: Today = due/overdue count, Inbox = waiting count; last tab in `@SceneStorage`), no new header: each place keeps `ChromeBar` (`NotesView.listColumn` / `listActions` move into the places) with exactly one row – Today: `todayPager` · "+"; Inbox: Triage · Select · "+" (New / Later is a segment as the first list row; the Weekly Review bar button goes to Today); Bowls: Sort menu · Settings gear · "+"; "+" uses `ChromePillButtonStyle(fill: .brandSky)`, long press = new note. Today's title on other days becomes the short form "Wed 2 Dec" (`TodayDay.title`: template `EEEdMMM`, year only when different) so it fits at full size beside ‹ › and "+"; `BowlsPlace.swift` (Pinned, All Bowls, Smart Filters, Archive, Recently Deleted – always present, "Empty" when empty), `AddSheet.swift` (Note, To-do, Meeting, Link · Capture: Scan Document, Photo or File, Import Audio, Import from Plaud · From Template + Edit · New Bowl…; "Into:" = current place), Settings is pushed onto the Bowls tab's stack from the gear (`SettingsView(isEmbedded: true)` as today, with `VoicesView` and `AcknowledgementsView` behind it); a "Settings" Go-To row in search is the second door (stage 5); `InboxPlace.swift` (segment New / Later; bundle card one line; "✦ Bowl" word in the row footer instead of the pill bar) |
| Reuse | `NoteRow`, `ProjectRow`, `TodayPage`, `ProjectPage`, `SmartFilterPage`, archive and trash pages from `NotesView`, `LaterSection` logic, `InboxBundleCard`, `RecordMeetingSheet`, `PlaudImportSheet`, `DocumentScanner`, `SettingsView(isEmbedded:)`, `VoicesView`, `WeeklyReviewView` (opened from Today) |
| Remove | `NotesView.home`, `UpNextRow`, `UpNextTile`, `TodayTile`, the `createMenu` fan and `createOption`, `FloatingActionButton` uses (Chat, Search, "+"), `roomForFloatingButtons()`, the red trash pill and the Import menu in the home and bowl bars, the "Archive N ›" header, the Weekly Review icon in the Inbox bar, Select / Share / Import pills on the bowl bar, `HomeCard` "Bowls Before “More”" (`HomeList.recentProjectsKey` no longer read), `ListPage.home` and `.chat` as stack pages (`.settings`, `.voices`, `.acknowledgements` stay, now inside the Bowls tab) |
| Effort | L |

iPad: keep `NavigationSplitView` for regular width, with the three places as the sidebar's first section (same order),
Details as a sheet. Not redesigned further in this plan.

### Mac

| | |
|---|---|
| Change | `Window/WindowState.swift` (`SidebarPage`: add `.bowls`; keep `.todos` as a page opened from Today / ⌘K, not a sidebar row; remove `.chat` as a sidebar page in stage 5), `Sidebar/SidebarViewController.swift` (groups: places Today / Inbox / Bowls with the bowls as children, Smart Filters + "New Smart Filter…", footer Archive / Recently Deleted always shown; bowl order from `HomeList.bowlOrderKey`), `List/ListHeaderView.swift` (Today: ‹ Today › + date line; Inbox: segment New / Later instead of the Later pill, Triage; bowl: people button + ⋯ bowl menu; Bowls page: sort pull-down), `List/NoteListContent.swift` (Today footer rows Open To-dos and Weekly Review; Bowls overview rows), `List/NoteListViewController.swift`, `App/AppMenu.swift` View menu (⌘1 Today, ⌘2 Inbox, ⌘3 Bowls, ⌘4 Archive, ⌘5 Recently Deleted, Open To-dos, Weekly Review, Triage Inbox), `MainWindowController.swift` toolbar (remove Import and Chat items; "+" menu gets the Import group: Photo or File…, Audio…, From Plaud…, From iPhone or iPad ▸, New from Template ▸, New Bowl…), `Settings/GeneralSettingsPane.swift` ("Sort Bowls By") |
| New | `List/BowlsOverview` content (all bowls like the iPhone tab, Smart Filters, Archive, Recently Deleted; ↩ / double-click opens) |
| Reuse | `Library`, `BowlShareMac`, sidebar context menu (becomes also the bowl header ⋯), `SmartFilterSheet`, `AppointmentCellView` |
| Remove | sidebar groups "Up Next" and "More", the To-dos and Chat rows, the conditional Archive / Recently Deleted rows, toolbar Import and Chat items |
| Effort | M |

Data impact: none. `homeBowlOrder` (per device) is now also read on the Mac; default Last Change on both (open
question 3). `homeRecentBowls` is ignored.

Tests: `ProjectOrderTests` (no limit, pinned first, same order function for both), a new `PlacesBadgeTests` (Today and
Inbox counts), `QuickActions` / deep-link tests for `today`, `bowls`, `todos`. UI tests to update: `TodayFlowTests`,
`TodoFlowTests`, `NotesFlowTests`, `NotesFeaturesTests`, `IntakeFlowTests` (they reach pages through the home tiles and
the floating buttons; switch them to tabs, the "+" pill in the bar, the Settings gear in the Bowls bar and the Add sheet; `AppHelpers.swift`).

Verify on screen: cold start (opens the last place; first launch Today), each tab's badge, "+" on every place and in a
bowl ("Into:" right), long press on "+" makes a note, swipe-back inside each tab, Archive and Recently Deleted reachable
when empty, deep links and widgets land in the right tab, iPhone SE width and Dynamic Type XXXL (bar pills stay whole, the title shrinks to 70 % and then truncates; "Wed 2 Dec", "Inbox", "Bowls" at full size on a 390 pt iPhone; long bowl names truncate as today), dark mode. Mac: ⌘1–5, sidebar drag & drop onto bowls and the Inbox, bowl sort shared, Today
paging (‹ › and ← → T).

**As built (stage 4):**

- iOS: `NotesView` stays the coordinator (no separate `PlacesView` file): on a phone a `TabView` with
  `Tab("Today")`, `Tab("Inbox")`, `Tab("Bowls")`, `Tab(role: .search)`, one `NavigationStack` per tab
  (`paths: [Place: [ListRoute]]`), the tab in `@SceneStorage("place")` (first launch Today). Badges: Today =
  `Places.todayCount` (open to-dos due today or before), Inbox = `Places.inboxCount`; the Mac sidebar shows the same
  numbers. `go(_ page:)` brings a place to the front at its start, or pushes a page onto the stack it belongs to
  (`ListPage.place`: Open To-dos → Today; bowl, smart filter, Archive, Recently Deleted, Settings → Bowls; chat →
  Search). The open entry is pushed onto the tab in front; switching tabs keeps each tab's entry, an empty new note
  left in another tab goes. iPad (regular width): the split view stays, its sidebar is the Bowls place with a first
  section "Places" (Today, Inbox, Search) pushing onto the one sidebar stack.
- New files: `Views/Places/BowlsPlace.swift` (Pinned, All Bowls "by …", Smart Filters + New Smart Filter…, Archive
  and Recently Deleted always, "No Bowls Yet" + New Bowl; `PlaceLinkRow` for fixed rows), `InboxPlace.swift`
  (segment New N / Later N as the first row, bundle card under it, empty Inbox with "Add" and when Later comes
  back), `AddSheet.swift` (Into: menu, Note · To-do · Meeting · Link, Capture, From Template + Edit, New Bowl…; the
  choice runs once the sheet is gone; a template that needs a title asks for it). `ProjectsPane.swift` gained
  `BowlMenuItems` (the bowl ⋯ and the long press of a bowl row), `BowlPinButton`, `BowlArchiveButton`.
- One-row bars: Today `‹ ›` · "+"; Inbox Select · "+" (Select becomes a filled Done while choosing, the
  `NoteSelectionBar` loses its own Done there); Bowls sort menu · gear · "+"; bowl ⋯ · "+"; Open To-dos "+" makes a
  to-do at once; Smart Filter ⋯; Recently Deleted Delete All. "+" is `ChromePillButtonStyle(fill: .brandSky)`,
  identifier `PlaceAdd`, long press = new note (also an accessibility action "New Note").
- Today: hint of the day on top (today only), Appointments, "Due" (red "Due N · M overdue" when late), Up Next (next
  7 days, at most 5, folds, `todayUpNextFolded`), fixed rows Open To-dos and Weekly Review (today only).
  `TodayDay.title` is now the short "Wed 2 Dec" (Today / Tomorrow / Yesterday stay words). `TodayTodos.upcoming`,
  `Places.newThisWeek` are shared with the Mac.
- `HomeList`: no limit any more (`recentProjectsKey`, `shownProjects` gone); `bowls(_:notes:order:)` = active bowls,
  pinned first, by `bowlOrder` (Last Change = newest of bowl and its entries); read by the Bowls place, the Mac
  sidebar and the Mac Bowls page. Settings › General "Home" card is now "Bowls" with only Sort Bowls By; "Daily Hint
  in Today".
- Links and shortcuts: `porridge://today`, `porridge://bowls` (`QuickAction.openToday/openBowls`), App Shortcuts
  Open Today / Open Bowls; `porridge://todos` and the To-dos widgets open Today › Open To-dos, `inbox` the Inbox tab,
  `search?q=` the search tab, `new` / `meeting` as before. **Entry links fixed:** `porridge://entry/<id>` used to be
  taken and dropped when it came before the list had loaded the entry (cold start), and opened via a deferred task;
  now `EntryLinkRouter.waiting` keeps it until the entry is there (also retried when the notes change) and it opens
  in the same update. UI test `testEntryLinkOpensAtOnce` (running app, two links, then `porridge://bowls`); unit
  test `PlacesTests.testEntryLinkWaitsUntilTaken`.
- Mac: sidebar Today · Inbox · Bowls (unfolds into every bowl in the shared order; folding is kept while the app
  runs) · Smart Filters (+ "New Smart Filter…" row) · Archive · Recently Deleted (always, with counts). The To-dos
  and Chat rows and the groups Up Next / More are gone. `SidebarPage.bowls` (Bowls page: Pinned, All Bowls, smart
  filters, New Smart Filter…, Archive, Recently Deleted as `ListItem.link` rows, `LinkCellView`). View: Today ⌘1,
  Inbox ⌘2, Bowls ⌘3, Archive ⌘4, Recently Deleted ⌘5, Open To-dos, Weekly Review, Triage Inbox. List head: Today
  ‹ Today › + date line + hint; Inbox segment New / Later (replaces the Later pill and the Weekly Review button) +
  Triage; bowl Share… + ⋯ (`BucketActions.addItems`, the same menu as the sidebar row, now in the design's order with
  Ask About This Bowl, Copy Link, Open in New Window); Bowls page sort pop-up. Toolbar: Import and Chat items gone;
  "+" = New Note, New To-do, Record Meeting, Add Link… | Photo or File…, Audio…, From Plaud…, From iPhone or iPad |
  New from Template | New Bowl…. Chat (no sidebar row until stage 5): AI › New Chat ⇧⌘K, Ask About This Bowl, the
  command bar's "Chat". Settings › General "Sort Bowls By". New windows open on Today.
- Where the old doors went:

  | Old | Now |
  |---|---|
  | Home "Up Next": Today tile, Inbox tile | Today and Inbox tabs (badges); Mac sidebar rows |
  | Home To-dos tile; Mac sidebar To-dos | Today › Open To-dos row; Mac View › Open To-dos, command bar |
  | Home bowl list with "More" | Bowls tab (all bowls, sort menu); Mac sidebar under Bowls, Bowls page ⌘3 |
  | Home Smart Filters section | Bowls › Smart Filters + New Smart Filter…; Mac sidebar group + row |
  | "Archive N ›" header; Mac conditional Archive | Bowls › Archive row (always); Mac ⌘4 row (always) |
  | Red trash pill; Mac conditional Recently Deleted | Bowls › Recently Deleted row; Mac ⌘5 row |
  | Gear in the home bar | Gear in the Bowls bar |
  | "+" fan (Note, To-do, Meeting, Link, Scan, Template, Bowl) | Add sheet; long press "+" = note; Mac "+" menu |
  | Import menu (home and bowl bar); Mac toolbar Import | Add sheet › Capture; Mac "+" Import group, File menu |
  | Floating Search | Search tab |
  | Floating Chat; Mac toolbar Chat, sidebar Chat | Search tab › Chat row, bowl ⋯ / ✦ Ask About This Bowl; Mac AI menu, command bar |
  | Inbox Weekly Review button (iPhone and Mac) | Today › Weekly Review row; Mac View › Weekly Review |
  | Inbox Later section / Mac Later pill | Inbox segment New / Later |
  | Daily hint in the Inbox | Top of Today (both) |
  | Bowl bar Select / Share / Import | Bowl ⋯ Select Entries / Manage Sharing… (Share Bowl…), Copy Link, Stop Sharing… / Add sheet |
  | Bowl row swipe Rename | Bowl ⋯ and long press Rename… |
  | Settings "Bowls Before More" | removed (no limit) |
  | Mac ⌘1 Inbox, ⌘2 To-dos, ⌘3 Chat | ⌘1 Today, ⌘2 Inbox, ⌘3 Bowls; Open To-dos and Chat as above |

- **Deviations:** `ListPage.chat` stays a page (pushed on the Search tab) until stage 5 merges search and chat. The
  "✦ Bowl" word instead of the suggestion pill bar and the one-line bundle card are left for stage 6 with the
  swipes (the `FilingBar` stays). No Triage pill on iOS (triage does not exist there yet: stage 6). Mac Bowls page:
  a single click opens a bowl (as in the archive), rows say "N entries" (no iPhone-style summary); Archive and
  Recently Deleted are the last rows of the outline, not a pinned footer; Up Next on the Mac does not fold. A view-only
  bowl's ⋯ also has Ask About This Bowl and Leave Bowl… (the table listed Pin, Copy Link, Export only). The Mac only
  asks for the calendars on Today when it does not run on test data (`PORRIDGE_TEST_DATA`).
- Tests: `PlacesTests` (badges, Up Next, new this week, links, page → place, entry link waits), `TodosTests` bowl
  order without limit and by entries; UI: `NotesFlowTests` updated to tabs / gear / Add sheet plus
  `testThreePlacesAsTabs`, `testAddSheetAndBowlMenu`, `testEntryLinkOpensAtOnce`; `PlacesShotsTests` writes
  screenshots to /tmp/porridge-s4-shots. `-seedEntryKinds` now makes its entries again on every launch, so a test
  that changed one (the meeting's bowl) does not break the next; `-emptyStore YES` (Debug) runs on an empty store in
  memory. `ChromePillButtonStyle` dims a disabled pill (Select in an empty Inbox). Debug driver: `page bowls|later`, `bucket-archive`, `smart-filter`, `list`, `plus-menu`, `toolbar`,
  `shot-sidebar`, sidebar geometry.

---

## Stage 5 · Search & Ask

Goal: one field for search, chat and (Mac) commands. First row always "Ask Porridge: …"; empty field: Recent Chats,
Recent Searches, Tags. Chat scope changeable at any time.

| | iOS | Mac |
|---|---|---|
| Change | `Views/Notes/TimelineSearchBar.swift` (`SearchPane`: scope chip Everywhere / Inbox / bowl, kind chips incl. Open To-dos, "Go To" rows for bowls, smart filters and places), `Views/Chat/ChatView.swift` (`ChatPage` pushed inside the search tab; scope and model pills always active), `Services/ChatService.swift` (scope read per question from `ChatThread.projectID`) | `MainWindowController.swift` (`NSSearchToolbarItem` → "Search or Ask", ⌘K focuses it; its results drop down below), `CommandBar/CommandBar.swift` (`CommandBarItems` complete: places, Open To-dos, Triage, Weekly Review, Import, Export, Smart Filters, bowl actions; `CommandBarController` hosts the same list anchored to the field, and stays a floating panel for the global shortcut / no window), `Window/MainSplitViewController.swift` (`ContentColumnViewController` no longer swaps to the chat list), `Detail/DetailViewController.swift` (chat in the detail column), `Chat/ChatListViewController.swift` (shown only via "All Chats…") |
| New | "Ask Porridge" row; Recent Searches (UserDefaults, last 10, per device); "All Chats ›" list | ⌘↩ asks, ↩ opens the best row, ⇧↩ Show All Results (search page in the list column with kind/tag pills and "Save as Smart Filter…"); AI › New Chat ⇧⌘K |
| Remove | the floating Chat entry (already gone in stage 4), `ChatBarActions` scope lock | sidebar Chat page (`SidebarPage.chat`), Edit › Find › "Search Notes… ⌥⌘F" |
| Effort | L | M |

Data impact: none. Changing scope mid-chat writes the existing `ChatThread.projectID` (local-only model, not synced);
earlier answers keep their sources.

Tests: `ChatTests` (scope change applies to the next question only), a new `SearchAskTests` for the ordering rule (Ask
row first, then smart filters / bowls, then entries by date) – put the ordering in a small shared type
(`Porridge/Services/SearchAsk.swift`) so it is testable; the Mac `CommandBarItems` reads from it for the non-command
rows (there is no Mac test target).

Verify on screen: typing never starts a chat by itself; ⌘K / ⌘↩ / ⇧↩ on the Mac; chat opens in the detail column and
the list keeps its place; confirm cards + the one undo; recent chats reopen; Dynamic Type.

---

## Stage 6 · Inbox work: swipes, Later, triage, multi-select

| | iOS | Mac |
|---|---|---|
| Change | `InboxPlace` rows: leading swipe "File" (into the first suggestion, full swipe files) + "Bowl…", trailing "Later" (opens `LaterPickerSheet` directly, no confirm dialog) + "Delete"; `Views/Notes/DocumentsPage.swift` (`NoteSelectionBar` → four fixed buttons Move · Later · Done · More (Document Kind, Set Sender…, Mark as Paid, Merge PDFs…, Delete) replacing the tab bar while selecting) | `List/NoteListViewController.swift` (triage keys: add ⌫ Delete; F files into the suggestion, else opens the bowl menu), `DetailsInspectorViewController` multi-select mode (`EntryDetails.sections(for: [Note])`): Bowl, Document Kind, Set Sender of N…, Mark N as Paid, Merge N PDFs…, Delete N |
| New | `Views/Places/TriageView.swift` (full screen, one entry at a time: File · Later · Skip · Delete, + Done for to-dos; "Other…" picks a bowl) | — |
| Reuse | `LaterPickerSheet`, `InboxSnooze`, `Documents.BulkChange`, `NoteMerger`, `UndoToast.move/trash/apply` | `TodoBridge`, `NoteOperations`, existing triage hint row |
| Remove | the Later confirmation dialog, the 8-control scrolling selection bar, the suggested-bowl pill bar under rows | — |
| Effort | M | S |

Data impact: none.

Tests: `InboxTests` / `InboxSnoozeTests` for the triage order and the "file into suggestion" path; UI test in
`IntakeFlowTests`: swipe to file, triage two entries, select three and mark as paid.

Verify on screen: swipes with VoiceOver actions (every swipe action also in the row's accessibility actions and LP menu),
triage on a to-do (Done), undo after each step; Mac multi-select with mixed kinds.

---

## Stage 7 · Editor bar, Settings, visual polish, onboarding

| | iOS | Mac |
|---|---|---|
| Change | editor keyboard bar (`NoteKeyboardBar` in `NoteBodyEditor.swift` / `Editor/NoteEditorController.swift`): fixed slots Aa · Checklist · ⊕ Insert (+ "Link to Entry [[") · ✦ Rewrite (`AIRewriteView`) · Outdent · Indent · Mic · Done; `EntryLinkSuggestions` as a card; Settings: `SettingsView.swift` (General keeps today's cards – You (Your Name), Plaud, Sync, Note Templates, Export, Hints, About – and its Home card becomes "Bowls" with only "Sort Bowls By"; Known Voices stays in Recording; "Summary Templates" name); `OnboardingView.swift` (last page shows the three places); visual tokens in `Theme.swift` (grouped backgrounds `systemGroupedBackground` / `secondarySystemGroupedBackground`, row icon 30/8 without border in `ThingsRowIcon`, active tab wash 17 %; `ChromeBar` itself is unchanged: 30 pt title, 34/9 square, 44×36 pills) | `Detail/NoteEditorView.swift` format bar gets ✦ (⌘J); `Settings/SettingsWindowController.swift` (tabs General · Recording · AI · Keyboard · MCP Server), `GeneralSettingsPane.swift` (Your Name, iCloud Sync, Plaud as today; new "Bowls" group with "Sort Bowls By"; Templates; Hints; Export; version – no "You" heading; Known Voices stays in Recording), `DictationSettingsPane.swift` + `ShortcutsSettingsPane.swift` → one `KeyboardSettingsPane`, `RecordingSettingsPane.swift` (unchanged content), `App/StatusItemController.swift` (shows recording state), `Onboarding/OnboardingController.swift` (sidebar slide), row icon 26/7 in `NoteCellView` |
| Remove | the floating dictation button (`DictationButton` overlay), the separate "Done" pill if the bar's Done replaces it | the separate Dictation and Shortcuts panes |
| Effort | M | M |

Also in this stage: a one-time dismissible "What’s new" card at the top of Today on both platforms (UserDefaults flag),
explaining tabs/sidebar, Search & Ask and where Settings went (gear in the Bowls bar).

Data impact: none (settings keys keep their names; the Keyboard pane reads the same `DictationSettings` / global
shortcut keys).

Tests: `BrandContrastTests` for the final surfaces; `AppSettingsTests` for moved settings keeping their values;
`EditorRenderingTests` unaffected (bar only).

Verify on screen: editor on iPhone with keyboard, ✦ with and without a selection, [[ suggestions above the keyboard,
small iPhone; Mac Settings window at every tab (Title Case everywhere); light, dark, Increased Contrast.

---

## What gets removed (summary)

- iPhone: the home page (Up Next tiles, bowl list with "More", Smart Filters section, "Archive N ›" header), the floating
  Chat / Search / "+" buttons and the "+" fan, the Import menu in the home and bowl bars, the red trash pill, the
  Weekly Review icon in the Inbox bar (the gear moves from the home bar to the Bowls bar), the entry page's chip row, speaker strip and bottom
  sections, the 13-item More menu, the 8-control selection bar, the four undo looks, the floating dictation mic,
  "Bowls Before “More”".
- Mac: the "Note" menu (→ Entry + AI), the toolbar More that repeated it, the toolbar Import and Chat items, ⌥⌘F,
  sidebar groups "Up Next" and "More" with To-dos and Chat rows, conditional Archive / Recently Deleted, `NoteChipsView`
  and the detail's bottom sections, the single-purpose Record column (now a mode of the inspector), the Dictation and
  Shortcuts settings tabs (merged), the chat's own toast and inline undo banners.

## Data / model impact (summary)

No new CloudKit fields in any stage. New local-only state: last selected tab (scene storage), recent searches
(UserDefaults), "What’s new" seen flag (UserDefaults), inspector open/closed (split autosave). `homeBowlOrder` becomes
shared by iOS and Mac (still per device). `ChatThread.projectID` (local, unsynced) may now change during a chat. If any
worker believes a synced field is needed, they stop and ask the owner first.

---

## Open questions for the owner (work starts with the recommended default)

1. **"+" as the last pill of the one-row bar** on Today, Inbox, Bowls and bowl pages (not beside the tab bar). Default:
   in the bar (HIG-safe, works on iOS 18, reuses `ChromePillButtonStyle(fill:)`). Alternative: a glass button beside the
   tab bar.
2. **Start place.** Default: the last used place; Today on first launch. Alternative: always Today.
3. **Bowl order default.** Default: Last Change on both (Mac sorted by Name until now). Alternative: Name.
4. **No "More" limit for bowls.** Default: show all bowls in the Bowls place and the sidebar. Alternative: keep the limit
   setting.
5. **Daily hint moves from the Inbox to Today.** Default: yes.
6. **Speaker strip leaves the meeting head** (Details › Speakers + tap in the transcript, meta says "N Speakers").
   Default: yes.
7. **Weekly Review only in Today (+ View menu / Search & Ask).** Default: yes.
8. **iPhone recorder cannot be minimized.** Default: keep full screen now; a minimizable recorder is a later project
   (it needs the recording state moved out of `RecordingView`).
9. **iPad.** Default: keep the split view, add the three places as its first sidebar section and Details as a sheet; no
   further iPad design now.
10. **Name "Open To-dos"** for today's To-dos view. Default: "Open To-dos".
11. **Mac ⌘1 becomes Today (was Inbox).** Default: yes, ⌘1–3 = the three places.
12. **Sidebar vs. inspector below 1130 pt** (last opened wins). Default: yes. Alternative: inspector as an overlay.
13. **Bowl sort setting synced between devices.** Default: no, per device as today.
14. **Delete Chat asks first and offers undo.** Default: yes.
15. **One-time "What’s new" card after the update.** Default: yes, in Today, dismissible.
16. **Settings door.** Default: a gear pill only in the Bowls bar (+ "Settings" in Search & Ask). Alternative: the gear on
    all three places (costs the title room on Inbox, which already has three pills).
17. **Today's title on other days.** Default: short "Wed 2 Dec" so it fits beside ‹ › and "+". Alternative: keep
    "Wednesday 2 Dec" and let the bar shrink it (~70 %).
