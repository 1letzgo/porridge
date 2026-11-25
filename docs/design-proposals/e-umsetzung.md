# Porridge redesign E ("Three Places + Details"): implementation plan

> **Revision 4 (2026-11-24): Today shows only what is open.** Owner decision: done to-dos are hidden from Today
> completely, on iPhone and Mac, on every day (chosen over a folded "Done" section or a counter); a to-do ticked there
> leaves with the undo toast. Bowls, the Inbox and Open To-dos are unchanged. Details: stage 4's As-built note.

> **Revision 3 (2026-11-24): Chat has its own tab / sidebar place.** Owner: "Wir haben Platz für 5 icons in der
> Tabbar. Gebe Chat seinen eigenen Platz." The chat is not folded into the search. iPhone tabs: Today · Inbox · Bowls ·
> Chat · Search; Mac sidebar: Today ⌘1 · Inbox ⌘2 · Bowls ⌘3 · Chat ⌘4, Archive ⌘5, Recently Deleted ⌘6. Search & Ask
> (Search tab, Mac toolbar field "Search or Ask" ⌘K) searches and goes to places, bowls, smart filters and commands;
> its first row "Ask Porridge: …" hands the question over to the Chat place, no answers inside the search. Ask About
> This Bowl opens the Chat place with the bowl as scope. Affected: stage 5 (rebuilt as described in its As-built note),
> the stage overview, open questions 7 and 16 (Search & Ask keeps the Weekly Review and Settings rows).

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
| 5 | Search & Ask (search + go-to + commands in one field; chat its own place, revision 3) | L | M | Search and Chat tabs / toolbar field = ⌘K, Chat sidebar place |
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
- **Owner decision (2026-11-24, after stage 5): Today shows only what is open.** Done to-dos are hidden from Today
  completely ("Ganz ausblenden", not a folded "Done" section or a counter), on iPhone and Mac, on today and every
  other day, also under an appointment (`TodayTodos.shown`). A to-do ticked in Today leaves the list with the one
  undo toast ("Done: “…”", `Undoable.done`; Undo also unticks the subtasks it ticked): `Todos.tick(_:leavesList:)`,
  the environment flag `ticksLeaveList` on iOS, the Today page's `onToggleDone` on the Mac. Done to-dos stay in their
  bowl / the Inbox and in Open To-dos' "Done Today" as before. `TodayTodos.done` / `doneToday` are gone.
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

**As built (stage 5, revision 3):**

- **Owner decision during the stage** (quoted): "Wir haben Platz für 5 icons in der Tabbar. Gebe Chat seinen eigenen
  Platz." So the chat is not merged into the search field: it is its own place on both platforms, and Search & Ask
  hands questions over to it. Everything else of the stage stands.
- Shared `Porridge/Services/SearchAsk.swift` (`@MainActor`, pure): `Scope` (Everywhere / Inbox / bowl; as a chat
  keeps it in `ChatThread.projectID`: nil, `SearchAsk.inboxKey` = "inbox", the bowl key – local-only model, no CloudKit
  field), `question`/`askTitle`/`askSubtitle` ("Ask Porridge: “…”", "Answers with sources · All Bowls"), `Target` +
  `places()` (Today, Inbox, Bowls, Open To-dos, Weekly Review, Archive, Recently Deleted, **Settings**, All Chats) +
  `targets(bowls:filters:notes:places:)` ("Smart Filter · 3 entries", "Bowl · 24 entries", archived bowls last) +
  `goTo` (FuzzyMatch, a name match beats a keyword match, ties: places, smart filters, bowls), `entries(…)` (scope,
  kind, all tags, text via the index/title/link/document; newest change first), `dateGroups`, `rows` (Ask, Go To,
  entries), `recentChats`, `RecentSearches` (UserDefaults `searchAskRecentSearches`, last 10, per device, "#tag text").
  `ChatService.scope(of:)` reads the scope per question (Inbox scope added), `ChatService.startChat(about:in:)`.
- iOS: `Place` gains `.chat` (tabs Today · Inbox · Bowls · Chat · Search, the tab in `@SceneStorage` as before; iPad
  sidebar "Places" gets a Chat row). `ListPage.chat` is the Chat tab's root (bar "Chat" · All Chats · New Chat,
  `ChatBarActions`). The scope pill is always a menu (All Bowls, Inbox, bowls); in a running chat it rewrites
  `thread.projectID` and holds from the next question (the old lock is gone). A cloud model shows its hint line
  (`SummaryModel.sendsHint`) under the pills. A new chat shows "Recent Chats" (3) with "All Chats" above the examples.
  Delete Chat (swipe, long press, VoiceOver action) asks first and offers the one undo (`ChatDeletion`). Search tab
  (`SearchPane`): field "Search or Ask", a scope chip (Everywhere ▾ / Inbox / bowls) before the kind chips, empty field
  = Recent Searches (with Clear) + Tags; results = "Ask Porridge: …" (hands over: a new chat about the search's scope
  opens in the Chat tab and asks there), "Go To" rows, then the entries by date. Return keeps the search as a recent
  one, never asks. Save as Smart Filter stays in the bar. `porridge://chat`, `QuickAction.openChat`, App Shortcut
  "Open Chat".
- Mac: `SidebarPage.chat` is a sidebar row again (after Bowls); View: Search or Ask… ⌘K, Today ⌘1, Inbox ⌘2, Bowls ⌘3,
  Chat ⌘4, Archive ⌘5, Recently Deleted ⌘6; Edit › Find › "Search Notes… ⌥⌘F" removed. The Chat place works as before
  stage 4: chats in the list column (New Chat, Delete Chat with confirm + undo), the open chat in the detail; scope
  pop-up always active (All Bowls, Inbox, bowls), cloud hint line under it. The toolbar field is "Search or Ask"
  (⌘K focuses it; `NSSearchToolbarItem.beginSearchInteraction`); its results hang below it in a non-key child panel
  (`CommandBarController.showAnchored`), the field keeps the keyboard: ↑↓, ↩ runs the selected row (at first the best
  one after "Ask"), ⌘↩ asks (hand-over to the Chat place via `WindowState.pendingQuestion`), ⇧↩ Show All Results (the
  search page in the list column with kind/tag pills and Save as Smart Filter…), Esc closes. Sections: Ask Porridge,
  Commands, Bowls & Smart Filters, Entries, Show All Results; empty field: Recent Chats, Recent Searches, Commands,
  Latest Entries. Commands now also: New Chat, Go to Chat, Import Photo or File…, Import Audio…, Import from Plaud…,
  Export Everything…, Settings, and the open bowl's ⋯ rows (from `BucketActions.addItems`) plus "New Note in <bowl>".
  Without a toolbar field (hidden toolbar, global shortcut) the same list is the floating panel with its own field.
  While the search page is open the field narrows it live (no panel).
- **Deviations:** the Mac's "Ask Porridge" asks about everything (no scope chip in the toolbar; the chat's pop-up
  changes it at once); the iPhone's scope chip is not saved into a smart filter (criteria have no scope). An asked
  question is not kept as a recent search (it is a recent chat). **Fixed:** leaving the Search tab cleared the query
  while the field (off screen) kept showing the old text over empty results; on the iPhone the Search tab now keeps
  its query like every tab keeps its place (the iPad's one stack still forgets it).
- Debug: `-chatStub YES` (Debug builds) answers without a model (`ChatStub`: the first two found items as sources,
  two ACTION lines when the question asks for a change). Driver: `search-ask <text>`, `search-ask-floating`,
  `search-ask-dump`, `search-ask-key return|ask|all|down|up|escape`, `shot-ask`, `windows`.
- Tests: `SearchAskTests` (row order, go-to ranking incl. Settings, scope keys, entries, date groups, recent searches,
  recent chats), `ChatTests` (Inbox scope, `startChat`, scope change applies to the next question only – with the
  stub), `PlacesTests` (five tabs, `porridge://chat`), UI `SearchAskFlowTests` (tabs, Ask/Go To/entries order, Settings
  row, hand-over + answer with sources + Confirm All + undo, Ask About This Bowl + scope change, Delete Chat confirm +
  undo, `porridge://chat`), `SearchAskShotsTests` → /tmp/porridge-s5-shots.

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

**As built (stage 6):**

- Shared: `Porridge/Services/InboxTriage.swift` (the queue taken at the start in the Inbox's order; `current(in:)`
  passes over entries that left the Inbox, so an entry brought back by Undo is in front again; `advance` for Skip and
  Done; `file(_:bowls:in:)` = into the suggestion with `Undoable.move`, false without one), `EntryMeta.suggestion(for:bowls:)`
  (the "✦ Bowl" of a row: first suggestion that is active and writable, only in the Inbox), `InboxBundle.line`,
  `Undoable.done([Note])` (Today, triage, the selection bar; "Done: “…”" / "N to-dos done"), `SearchAsk` Go-To row
  "Triage Inbox" (`.triage`, subtitle "Command"; the Mac keeps its own command).
- iOS rows: `NoteListRow(inInbox: true, suggestion:)` swipes right "File" (labelled with the bowl's name and ✦, full
  swipe files; without a suggestion only "Bowl…") + "Bowl…" (`BowlPickerSheet`: Suggested, then the bowls), left
  "Delete" + "Later" (`LaterSheet`: the times at once with "“…” leaves the Inbox and comes back with a notification.",
  Pick Date & Time… pushes `LaterDatePage`). Each also an accessibility action; the long press gained File into "…" and
  Drop Suggestion. `NoteRow` shows `SuggestionWord` ("✦ Reading", violet, tap files) after the status. The Later rows
  (segment Later) keep their swipes; their Later opens the same sheet.
- **Deviation – Later sheet:** the plan said "opens `LaterPickerSheet` directly"; the mockup (HTML 2.4) shows a sheet
  with the times, so `LaterSheet` is that sheet and the graphical picker is its last row. The confirmation dialog
  (`LaterDialog` / `.laterDialog`) is gone.
- Bundle card: one line, "New bowl “Berlin” for 3 entries?" / "3 entries for “Reading”?" (the mockup's "3 entries look
  like a new bowl “…”" did not fit one line beside Review… on a 390 pt iPhone), the titles are the VoiceOver hint
  (Mac: tooltip). **Fixed:** the card's search for a bundle hung on an empty `Group`, whose `.task` never ran, so the
  card never appeared on iOS; it is a `VStack` now.
- Triage (iPhone): `Views/Places/TriageView.swift`, a full-screen cover from the bolt pill (Inbox bar: Triage · Select ·
  "+", both dimmed in an empty Inbox / in Later) and from Search & Ask. ChromeBar "Triage" · Done; first row "Entry 2
  of 12 · New"; the card (icon, title, `EntryMeta.facts`, summary or preview, document line with Paid/Unpaid, due
  day), "✦ Suggested bowl: …" or "No bowl suggested" · Other…; tiles File · Later · Skip · Delete (+ Done for an open
  to-do); "Next" with the following two; at the end "Inbox Triaged". File without a suggestion opens the bowl list.
  Its own undo toast (the root's is under the cover).
- Selection (iPhone, Inbox and bowl pages): `NoteSelectionHeader` ("N Selected" · Select All / Select None) as the first
  row, `NoteSelectionBar` as a glass capsule in `.safeAreaInset(.bottom)` while `NotesView` hides the tab bar
  (`.toolbar(.hidden, for: .tabBar)`): Move (menu: Inbox, bowls) · Later (menu with the times; dimmed outside the
  Inbox) · Done (open to-dos among the chosen; VoiceOver "Mark as Done") · More (Document Kind ▸, Set Sender…, Mark as
  Paid / Unpaid, Merge N PDFs…, Delete N Entries; `.menuOrder(.fixed)`). Not applicable = dimmed, never hidden. The
  old scrolling 8-control bar and `FilingBar` / `SuggestionPill` are removed.
- Mac: `NoteCellView` shows "✦ Bowl" (a borderless button after the status, click files with the toast and ⌘Z)
  instead of the pill row with its cross; the list's context menu has File into "…" and Drop Suggestion. The bundle
  banner is one line (stopped spinner no longer takes room in `PanelView`). Triage: F files into the suggestion at
  once (else the bowl menu as before), ⌫ deletes with Undo and moves on, the hint row lists J/K · F · L · D · ⌫ · Esc.
  Multi-select inspector unchanged (it already had Bowl, Later, Due, Kind, Set Sender of N…, Mark N as Paid, Merge N
  PDFs…, Delete N). **Fixed:** the fixed rows (Open To-dos "N open · M overdue", smart filters) kept their old counts
  after a change; they are reloaded with the list now.
- Tests: `InboxTests` (triage order, passing over and coming back, file into the suggestion + Undo, bundle line, Go-To
  "Triage Inbox"), `InboxSnoozeTests` (Later from a swipe/triage + Undo); UI `IntakeFlowTests`
  (`testSwipesFileIntoTheSuggestionAndPutAwayForLater`, `testTriageTwoEntries`, `testSelectThreeAndMarkAsPaid`, now `testSelectThreeAndSetTheirKind`),
  `InboxShotsTests` → /tmp/porridge-s6-shots (`TEST_RUNNER_SHOTS_SUFFIX=-dark` for dark). Seeds: `-seedInbox YES`
  (with `-emptyStore YES`; Mac driver `seed-inbox`, test data only), `-quietNotifications YES` (no notification prompt
  when putting away). Mac driver: `triage`, `triage-key f|l|d|j|k|delete|escape`, `tick <title>`.

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

**As built (stage 7):**

- **Editor bar.** iPhone `NoteKeyboardBar`: fixed places Aa (format menu) · Checklist · ⊕ Insert (now with "Link to
  Entry [[", which types "[[" so the entry suggestions come up as when typing it: `NoteEditorController.beginEntryLink`)
  · ✦ Rewrite (violet; without a selection an alert on the editor says to select first) · Outdent · Indent · Mic · Done. Like a tab
  bar its symbols stop at xxLarge and a long press shows the large content viewer. **Deviation:** the floating mic is
  gone as a door, but while dictation runs (the keyboard and with it the bar are away) its red button stays as the
  way to stop it. Mac `NoteEditorView`: the same order (Format · Checklist · Insert · ✦ · Outdent · Indent), ✦ is ⌘J and
  asks for a selection the same way; Insert has Link to Entry [[ too.
- **Settings.** iPhone General: You · Sync · Plaud · Bowls (Sort Bowls By) · Note Templates · Hints · Export · About;
  **deviation:** the plan listed the iPhone's cards as You, Plaud, Sync, …; both platforms now use the Mac's order.
  "Custom Templates" is "Summary Templates" on both. Mac: tabs General · Recording · AI · **Keyboard** · MCP Server;
  `KeyboardSettingsPane` is the former Dictation pane with the other system-wide shortcuts (Record Meeting Now, Search
  or Ask – the "Command Bar" shortcut is named so now) below it; the keys are unchanged, `show(tab: "dictation" |
  "shortcuts")` lands on Keyboard. General: Your Name · iCloud Sync · Plaud · Sort Bowls By · Note Templates · Hints ·
  Export · Version (no "You" heading). **Fixed:** the form's separators could come out taller than wide and draw as
  short vertical lines with a gap (`SettingsForm.separator` now fills the row, 1 pt high).
- **Status item:** while a meeting is recorded the menu bar symbol is a red `record.circle.fill`, and its menu starts
  with "Recording a Meeting · 12:04" and Show Recording.
- **Tokens.** Row icon: iPhone `ThingsRowIcon` 30 pt (grows with the text up to 42), corner 8, 15 % wash, no border,
  symbol in the readable value; Mac `KindIconView` 26 pt, corner 7, the same wash, no border. **Deviation:** the grouped
  backgrounds (`systemGroupedBackground` page with white inset cards) are not applied: every list is a plain list on
  the white page with list headers as rows (`cardList`, `ListHeader`), so inset cards would mean rebuilding each page's
  headers as real sections; DESIGN.md keeps "quiet white pages". The 17 % active-tab wash is the system tab bar's own
  (Liquid Glass) and was left to it; `ChromeBar` unchanged at normal sizes.
- **Onboarding.** iPhone: the last page lists the places (Today, Inbox, Bowls, Chat, Search; `WhatsNew.places`), every
  page scrolls when the text does not fit. Mac: the last step lists them too ("Search or Ask (⌘K)").
- **What's New** (`Porridge/Services/WhatsNew.swift`, shared): one card, shown when the onboarding was done before (an
  earlier version ran here) and `whatsNewSeen` (UserDefaults, this device) is not set; finishing the onboarding sets it,
  so a new install never sees the card. Items: Three Places (Settings = gear in Bowls), Details, Search or Ask (+ the
  Chat tab), Triage, Inbox Swipes (Mac: Filing with "✦ Bowl"), Choosing Several (the selection bar; Mac: the inspector),
  Today Shows What Is Open. iPhone: the first row of Today's list (scrolls away), "Got It" and ×. Mac: a panel in
  Today's head above the hint (it does not scroll with the list). UI tests pass `-whatsNewSeen YES`; `-resetWhatsNew YES`
  (Debug) shows it again.
- **Large text (AX sizes, iPhone).** `NoteRow`'s footer was one line of parts that keep their width; with the largest
  sizes it grew wider than the screen and the list centred the row, cutting the icon and the first letters off
  ("nvoice NV-2026-1142") in Inbox, Today, search and bowls. Now the parts wrap (`WrapLayout`, nothing keeps a width
  wider than the row) and the thumbnail is left out. `ChromeBar`: the title gets a row of its own under the pills (two
  lines, at most 52 pt; at normal sizes the one-line title may shrink to 60 %, so "Meeting" fits beside three
  pills), the pills grow to 56 × 46 and their symbols to accessibility 1 (no more "Meeti…" / "Kitchen…"
  with tiny buttons). `TabSwitcher` (Summary/Transcript, Inbox New/Later, export) becomes capsules that wrap; Settings'
  area pills wrap; `ListHeader`'s quiet word goes under the title; chat scope and model pills, Recent Chats' head, the
  confirm buttons and the answer's source pills stack; the search field grows, its chips wrap and the kinds become one
  menu ("All Kinds ⌄"); the selection bar's words stop at xxxLarge with the large content viewer; the selection header
  and the Later sheet's rows stack (the sheet opens large); bowl rows take three lines; the subtask circles of the
  editor grow with the body text (`NoteMarkdown.checkboxSize`, up to 40 pt). Triage's Later tile is a light sky wash
  with the outlined clock (the navy one looked heavy).
- **Search or Ask (findings).** Names now fit strictly (`FuzzyMatch.strictScore`): a word start, a run of four letters
  or more inside a word, or the first letters of words; extra words only at word starts and from three letters. So
  "cha" no longer finds "Kitchen Renovation", "bow" no longer "Go to Archive" / "Export Everything…", "design" no
  longer Record Meeting. `SearchAsk.score` is shared by the iPhone's Go To rows and the Mac's commands. Return runs
  `SearchAsk.best`: the closest fit by name (exact > starts with > every word starts a word > loose), among equals a
  bowl/smart filter, an entry, a place, then an action; an action never by a loose fit and never over an entry or bowl
  that fits as well; otherwise Show All Results. "design" → Design Review, "Chk" → the bowl, "bow" → Go to Bowls, "Q4" →
  Q4 Planning. The Mac's search page lists "Bowls & Smart Filters" before the entries (Show All Results for "Q4"). The
  empty detail says "No Entry Selected / Pick an entry from the list." (Mac and iPad).
- **Mac narrow columns:** `PanelView` (the Inbox's bundle card, the entry's state panels) wraps its text at the width
  it gets instead of cutting it; the sidebar's minimum is 200 pt (was 180), so "Recently Deleted" with its count fits.
- **Tests and seeds.** `-seedTodos` and `-seedMeetingWithTasks` remove what an earlier launch made (by title; the bowl
  when it is empty) before seeding again, so a full run has no second "Chk"/"Garden"; the screenshot tests write to
  `SHOTS_DIR` (`TEST_RUNNER_SHOTS_DIR=…` for xcodebuild) else their stage folder. **Product bug fixed:** on a fresh
  install `NLContextualEmbedding.requestAssets` can take minutes or never answer, and every question waited for it on
  "Searching your notes…"; `TextEmbedder` now waits 4 s at most, the download goes on, and until it is there answers and
  the index use words only. Tests: `SearchAskTests` (strict matching, command words, fit, the best row),
  `PlacesTests` (What's New once / never after onboarding, its items on both platforms), UI `Stage7ShotsTests`
  (What's New, onboarding's places, editor bar ✦ / Link to Entry, meeting, Settings), `PlacesShotsTests` closes the
  bowl menu above it (at AX sizes the left-edge tap chose Select Entries and hid "+"), `InboxShotsTests.testToday`
  scrolls to the to-do. Mac driver: `shot-settings <path>`.

**As built (later, owner decision):** documents keep no payment status and no payment deadline. Paid/Unpaid/Overdue,
Pay By, Mark as Paid/Unpaid (rows, chips, Details, inspector, Entry and ⋯ menus, selection More, triage card), the
payment words of search and chat, the due day the device and the model read, and the export's due/paid keys are gone;
the notes on "paid" in the stages above are historical. `DocumentInfo.dueDay`/`isPaid`/`paidDay` stay stored, unused.

**As built (owner revision 5, 2026-11-25, after the owner's review on his iPhone):** placement changes; the notes on
the tab bar, the Chat tab, Today's fixed rows and "+" in the bars in the stages above are historical.

- **"+" is the middle of the tab bar (iPhone).** Tabs Today · Inbox · **+** · Bowls · Search (`TabSlot.bar`). The
  middle slot is a tab without a stack (`TabSlot.add`): the `TabView` selection is a binding that opens the Add sheet
  for it and keeps the place in front. Over the slot lies `TabBarAddButton`, a sky circle of 40 pt (36 pt below 390 pt screen width), 48 pt to touch (first 54 pt: it ran into the Inbox's badge and selection capsule; a badge "120" ends 21 pt from the middle on the 375 pt iPhone SE, 24 pt at 390 pt, measured with `-seedInboxCount 120`, `testPlusLeavesRoomForAThreeDigitBadge`) with a navy `plus`
  (fixed size, large content viewer, VoiceOver "Add" with the action "New Note"), `PlaceAdd` as before; a long press
  makes a note. The Search tab is a plain tab now (the search role sets it apart at the edge, which would move "+" off
  the middle). The circle is put 52 pt above the screen's bottom edge: measured as the middle of the bar's slot on the
  iPhone 16e and the iPhone SE alike, and checked against the slot in `TabBarFlowTests`. It hides while choosing
  several (with the tab bar); Triage, sheets and the keyboard cover it. The "+" pills left the bars of Today, Inbox,
  Bowls and bowl pages on the iPhone; on the iPad (no tab bar) the pill stays. Open To-dos keeps a green "+" pill of
  its own that makes a to-do at once (`TodosAdd`).
- **Search | Chat share the last tab.** `SearchSide` (`searchSide` in UserDefaults) with a `TabSwitcher` on top of the
  Search tab (capsules at AX sizes); the bar's title, square and pills follow the side (Save as Smart Filter / All
  Chats · New Chat). `Place.chat` is gone; `ListPage.chat` stays as the way there: `go(.chat)` / `go(.search)` pick the
  side and bring the Search tab to its start. "Ask Porridge", Ask About This Bowl, `porridge://chat` / Open Chat,
  All Chats (Go To) land on Chat; `porridge://search?q=` on Search.
- **Open To-dos and Weekly Review left Today** (iPhone and Mac) and are one card at the end of the Inbox's New side
  (`InboxEndCard`): "Open To-dos · 5 open · 1 overdue" (overdue red, semibold), "Weekly Review · This Week · N new
  entries". Shown also when the Inbox is empty: the empty message is then a row of the list above the card (the old
  overlay would have covered it on a small phone), and its "Add" button went (a button in a list row makes the whole
  row a button; "+" sits right below). `ListPage.todos` now belongs to the Inbox tab (`porridge://todos`, the To-dos
  widgets and the overdue hint open it there). Go To rows in Search keep both.
- **Gear in Today's bar** (‹ › · gear): Settings is pushed onto Today's own stack (`go`: settings pages stay on Today
  when Today is in front; from elsewhere on Bowls, as before). The gear in Bowls stays (`PlaceSettings`).
- **Start on Today.** The tab is `@State` (was `@SceneStorage`): every launch starts on Today, a link, widget,
  shortcut or notification moves on from there (they run after the first appearance), the background keeps the tab.
  Mac: `RestoredState.apply` sets Today and keeps only the open chat; AppKit still restores the window's frame.
- **Chat keyboard.** The conversation had `scrollDismissesKeyboard(.interactively)`, but a short chat does not scroll,
  so nothing took the keyboard away. Now a tap anywhere in the conversation (also its empty part) and sending a
  question put it away; the search's results and its empty page do the same on a tap. "Ask Porridge" lets it go too.
- **Mac.** The Today list lost its two fixed rows; the Inbox list ends in the same two rows drawn as one card
  (`CardRowView`, rounded on the outer edge, the table's row gap is the line between them), also when the Inbox is
  empty (the message shows over the list then and lets clicks through). Driver: `scroll-end`.
- Texts: What's New (Three Places: tabs with "+" in the middle, gear in Today and Bowls; Search or Ask: switch to
  Chat; Today Shows What Is Open: Open To-dos and the Weekly Review at the end of the Inbox), the onboarding's last page
  (iPhone: Today, Inbox, Add, Bowls, Search and Chat; Mac unchanged but the Inbox line), DESIGN.md. The What's New flag
  is unchanged, so who dismissed the card does not see it again.
- Tests: unit `PlacesTests` (tab bar order with "+" in the middle, pages → places with Open To-dos on the Inbox and
  the chat on Search, `SearchSide`, "+" fits the bar, chat and search links, What's New and the onboarding's places);
  UI `TabBarFlowTests` ("+" on the middle slot and keeping the tab, Add sheet Into: Inbox / the bowl and the long
  press, gear in Today, start on Today after Bowls and the background, the Inbox card to Open To-dos and Weekly
  Review, the empty Inbox's card, the chat keyboard by tap, send and drag, the search's by drag),
  `SearchAskFlowTests.testSearchAndChatShareTheLastTab` (switch, kept side across a launch),
  `testTheChatAndSearchLinksOpenTheirSide`; the tests that tapped the Chat tab, the bar's "+" or Today's Open To-dos
  row now use the Search tab's side, "+" of the tab bar and the Inbox card. `Revision5ShotsTests` →
  /tmp/porridge-s10-shots.

**As built (owner revision 6, 2026-11-25, after the owner looked at revision 5 on his iPhone):** three iPhone
changes; the notes on the tab bar's "+", the Bowls place's last rows and the Chat side's bar above are historical.

- **The raised "+".** The system's floating tab bar gives its five slots the same width and draws the selection
  capsule wider than a slot (the Inbox's capsule ended 25 pt from the middle at 390 pt, a badge "120" 24 pt), and it
  ignores `itemPositioning`/`itemWidth` (tried). So the bar is drawn by the app now: `PlaceTabBar` (a glass capsule
  on iOS 26 and later, `.bar` material before) over the bottom of the `TabView`, whose own bar is hidden
  (`.toolbar(.hidden, for: .tabBar)` on each tab's stack). `TabBarLayout` sets it out: bar 62 pt high, 21 pt above
  the screen's bottom edge, 20 pt from the sides (14 pt below 390 pt, at most 420 pt wide); the middle slot is the
  circle and 14 pt (13 pt) on each side, the four tabs share the rest (63 pt at 390 pt, 64 pt at 375 pt). The circle
  (`TabBarAddButton`) is 64 pt (58 pt below 390 pt), rises 12 pt (10 pt) above the bar's top edge, sky to a deeper
  sky (`#0D99DB`) top to bottom, navy "+" at 42 % of the circle, a white 35 % rim and a soft blue shadow. A badge
  starts 2 pt right of its symbol's middle and grows toward the middle slot; "120" ends 8 pt before the circle at
  390 and 375 pt, the Inbox's capsule (as wide as its slot) 14 pt (13 pt) before it. Tabs: symbol 22 pt, name 10 pt
  semibold, chosen tab in the accent color on a soft capsule; fixed at every text size (`.dynamicTypeSize(.large)`),
  large content viewer for each tab and "+"; VoiceOver: "Today"/"Inbox" with the badge as value, selected trait,
  ids `TabToday`… and `PlaceAdd` as before, the bar `PlaceTabBar` (the `isTabBar` trait does not make it an
  `XCUIElement` tab bar, so the UI tests use `app.tab(_:)` and `app.placeTabBar`). Tapping the tab in front takes
  its stack back to its start (as the system bar did). The pages keep 101 pt (99 pt) from the screen's bottom edge
  free (`safeAreaPadding`, the window's own safe area subtracted), so lists scroll under the bar and the last rows
  and the Inbox's end card are reachable above the circle; with a software keyboard up (`keyboardWillChangeFrame`)
  that room goes and the keyboard covers the bar, as before. While choosing several the bar is gone (the selection
  bar takes its place); Triage, sheets cover it. Deviation: on the iPhone SE the 58 pt circle is 4 pt lower than the
  62 pt bar; it is "taller" in that it reaches 10 pt above the bar's top edge.
- **Bowls · Archive · Deleted.** A `TabSwitcher` (the Inbox's component: segments, capsules at AX sizes) on top of
  the Bowls tab, `BowlsSide` as `@State` (every launch on Bowls; kept while the app runs), counts in every segment
  ("Bowls 8", "Archive 1", "Deleted 11"). Bowls: Pinned, All Bowls, Smart Filters as before (`BowlsPlace` lost its
  Archive and Recently Deleted rows). Archive: the archived bowls ("Nothing Archived" when empty). Deleted: Recently
  Deleted with "Notes are deleted after 30 days.", its rows' actions, "Delete All" in the bar (`TrashDeleteAll`).
  The bar: Sort only on Bowls, the gear on all three. `go(.archive)` / `go(.trash)` select the Bowls tab and that side
  (the Go To rows of the search), `go(.bowls)` the Bowls side. "+" there adds to the Inbox (no bowl is
  open). The iPad's sidebar has the same switch.
- **Search tab, Chat side.** The bar's title and square stay "Search" on both sides. The list pill (All Chats / Back
  to Chat) and `ChatBarActions` are gone. While a conversation is open the bar has a back pill and "New Chat"
  (`ChatNewChat`); back goes to All Chats when the chat was picked there (`ChatNavigation.returnsToList`), else to the
  chat's start; All Chats has a back pill to the start. All Chats is reached from the Recent Chats card (shown at the
  start whenever a chat is stored) and the Go To row; the tab stays on its Chat side all the way.
- Texts: the onboarding's Bowls line (iPhone) says "the switch on top shows the Archive and Recently Deleted"; What's
  New names nothing removed and is unchanged; DESIGN.md. Mac: no change.
- Tests: unit `PlacesTests` (`testTheTabBarPlusFitsTheBar` on `TabBarLayout` at 375/390/402/440 pt: size, rise, on
  screen, capsule and badge "120" clear of the circle, tabs at least 60 pt; `testTheBowlsTabHasThreeSides`,
  `testTheChatSideGoesBack`); UI `TabBarFlowTests` (`testPlusSitsOnTheMiddleOfTheTabBar`: order, centred, taller than
  the tabs and above them, Inbox and Bowls slots end before it; `testPlusLeavesRoomForAThreeDigitBadge`: each tab
  chosen with "120", pictures; `testTheInboxEndCardClearsThePlus`), `Revision6FlowTests` (the three sides, Sort and
  Delete All, "+" into the Inbox, kept while running and Bowls after a cold launch; Go To Archive / Recently Deleted;
  the Chat side's back, All Chats and New Chat), `Revision6ShotsTests` → /tmp/porridge-s11-shots. Tests that tapped
  the Archive / Recently Deleted rows or the bar's All Chats now use `app.bowlsSide(_:)` and `app.openAllChats()`.

**As built (owner revision 7, 2026-11-25):** two changes after the owner looked at revision 6 on his iPhone.

- **The Inbox's card on top.** Open To-dos and Weekly Review (`InboxEndCard`, the name kept from revision 5) are the
  first row of New, under the New / Later switch and the bundle line, above the entries; with an empty Inbox above
  its message. Content and behaviour unchanged; Later has no card, as before. Mac: the card's section is the first of
  the Inbox list (`NoteListContent`), the empty message still lies over the list below it. What's New says "at the
  top of the Inbox". Tests: `testTheInboxCardIsOnTopAndTheLastRowClearsThePlus` (card under the switch, entries under
  the card, the last entry scrolls clear of "+"), `testEmptyInboxShowsTheCard` (card above the message); the shots
  are named `inbox-top-card`.
- **Symbol and words close together in rows.** A `Label` with `.titleAndIcon` in a list row keeps the list's icon
  column: about 18 pt between a small symbol and its words (Today's appointment line "18:00–22:00 📁      SPD /
  Politik", the bowl names and other footer labels of entry rows). `TightLabelStyle` (`.labelStyle(.tight)`, 3 pt
  as the due day of a to-do) replaces it there. The space under the appointment row before "Due" is the same section
  gap as before Up Next (measured 42 pt vs 40 pt at 390 pt); unchanged. Mac: the appointment's line is one text
  ("18:00–22:00 · Bowl · 2 linked entries"), not affected. Debug: `-seedAppointment <bowl>` adds an appointment
  today 18:00–22:00 filed into a new bowl of that name (only in memory, shown as if the calendar were allowed).
- **Appointments open and live in their bowl** (after the owner's look at 16715e9). A tap on an appointment row opens
  it read only: iPhone `AppointmentSheet` (Today and a bowl), Mac a popover by the row (`AppointmentActions.popover`).
  A bowl's page lists the appointments of the series filed into it (`BowlAppointments.rows`: one row per series, the
  next occurrence not over, else the last; upcoming first, then past; read from `TodayCalendar.windowAppointments`,
  180 days back to 365 ahead, cached per calendar change), with the day in the row and ↻ for a repeating one. Today
  keeps the day's occurrence. The Inbox never listed appointments (they are no `Note`s); unchanged. No model field:
  `CalendarAppointment` (Codable, not SwiftData) gains `location` and `repeats` (optional, old remembered ones decode).
  Tests: `AppointmentLinkTests.testABowlShowsItsAppointmentsOncePerSeriesUpcomingFirst`,
  `testAppointmentsNeverFillTheInbox`.
- **Today's unfiled appointments in the Inbox** (owner: "Inbox Termine von heute"). New shows, under the card and
  before the entries, a group "Appointments": today's appointments in no bowl (`InboxAppointments.rows`: overlapping
  the day, each series once, all-day first). Filing one (row menu or the sheet's Bowl) takes it out. Not counted in the
  badge (`Inbox.notes` unchanged), not in Triage, Later or choosing several. Mac: the section `inbox-appointments`
  after the card. Test: `testTheInboxShowsTodaysUnfiledAppointmentsOncePerSeries`.
- **A bowl with appointments is not empty** (owner: "Bowls werden trotz Terminen als empty angezeigt"). The rows of
  the Bowls place and the archive (iPhone `ProjectContent.summary`, Mac `BucketCellView`) name the filed appointments
  (each series once, `BowlAppointments.counts`) and say "Empty" only with neither entries nor appointments; the bowl's
  page shows its empty state only then (already so with All). The counts come from `AppointmentLinks.appointmentCounts`:
  one pass over `TodayCalendar.windowAppointments` (read once per calendar change), cached until the calendar or a
  filing changes, never a calendar query per row. Mac reloads the Bowls place and the archive on those changes.
  Widgets show no bowl summaries. Test: `testABowlWithAppointmentsIsNotEmpty`.

**As built (owner revision 8, 2026-11-25):** owner: "Termine sollen ein normaler Eintrag in einem Bowl sein … wenn an
einem Termin ein anderer Eintrag verknüpft ist, rücke ihn ein, analog der Logik auf Today".

- **No "Appointments" section on a bowl's page.** Each appointment of the bowl (`BowlAppointments.rows`, one per
  series, its next occurrence not over, else its last) is a row of the one list under All, in the row form it had
  (calendar icon, title, day and time, ↻), placed by the start of the occurrence shown among the entries' last
  changes (`BowlListing.rows`): pinned entries first, then newest first, so an upcoming appointment leads the unpinned
  entries and a past one stands among those changed around its day. Under it, moved in as in Today (iPhone
  `.underAppointment()`, 24 pt; Mac `NoteCellView.isIndented` from `Built.indented`, which Today now uses too), the
  entries of this bowl linked to any occurrence of its series, newest first (`AppointmentLinks.underAppointment`, the
  order of Today); they are not listed again at their own place. Done to-dos go under it too (a bowl shows them;
  Today hides them everywhere). Entries linked to it in other bowls or the Inbox are not shown; an entry whose
  appointment is filed elsewhere, in no bowl or outside the calendar window stands at its own place.
- **What the row offers.** A tap opens the appointment (iPhone sheet, Mac popover); its ⋯ / context menu stays Record
  Meeting (while not over), New Note and Bowl. No swipe, selection, pin, triage or delete. The other filters (To-dos,
  Meetings, …) and choosing several show no appointments; their entries stand at their own place there. The linked
  count of the row is the number of entries under it; on the Mac the row no longer names its own bowl.
- **Counts.** The All chip (iPhone and Mac) and the number at the end of a bowl's row in the Bowls place count the
  appointments too; the summaries stay ("1 Appointment · 1 Meeting · 1 Note", Mac "2 entries · 1 appointment"). Bowl
  pages have no search of their own. Inbox and Today unchanged. Test:
  `AppointmentLinkTests.testABowlListsItsAppointmentsAmongTheEntriesWithTheirEntriesUnderThem`.

**As built (owner revision 9, 2026-11-25):** owner: "zeige in den reitern kein 0 an. nur wenn wert vorhanden. wir
brauchen kein later in inbox. dinge bleiben solange dort bis zugeordnet", then "packe stattdessen open todos als todos
in das register. weekly reviews als button auf home in navbar".

- **No "0" on a switch, segment or chip** (`Places.countedTitle`): Bowls · Archive · Deleted ("Archive", "Deleted
  27"), the Inbox's New · To-dos (iPhone and Mac), a bowl's filter chips (iPhone `ProjectPage.chip`, Mac
  `ListHeaderView.filterPill`). The tab bar's badges and the Mac sidebar's counts already left out 0.
- **No Later.** "Later" was the dated snooze of stage 6 (`InboxSnooze`): an Inbox entry hidden until a time, listed
  on the Later side, then back with a notification and "Back from Later" for a day. It is gone with every way to it:
  the Later side and the switch New / Later, the swipe, the long press and VoiceOver action, Triage's tile and the
  Mac's L, the selection bar's button (now Move · Done · More), ⋯ More › Later, Entry › Later and Details' Later
  (Mac), "Back to Inbox Now", the notifications and their scheduler, the widgets' Later timeline. The Inbox lists
  every entry in no bowl (`Inbox.notes`, `Places.inboxCount`, triage, badge, widgets, hint, bundles). The stored keys
  (`@snooze`, `@snoozeBy`, `@unoffered` in `todoSuggestionsRaw`) are no longer read or written: entries put away
  before are in the Inbox again at once; `@unoffered` still means "no suggestions offered" and the keys go with the
  next change of the suggestions. Notifications planned before are removed when the app becomes active.
- **To-dos in the Inbox's switch.** The Inbox's switch is New · To-dos; To-dos is the former page Open To-dos (same
  groups, rows and green "+"), every launch starts on New. The card at the top of the Inbox is gone (iPhone and Mac);
  today's appointments in no bowl lead New. Every way to Open To-dos (Go To, the overdue hint, quick action, widgets,
  `porridge://todos`, Mac View › Open To-dos and the command bar) opens the To-dos side; on the Mac it is the page
  `.todos` shown under the Inbox's head and sidebar row.
- **Weekly Review in Today's bar:** iPhone a pill (`calendar.badge.checkmark`, "Weekly Review") between ‹ › and the
  gear; Mac a button in Today's head; Go To, View › Weekly Review and the command bar stay.

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
