# Porridge design

The look follows Things 3: quiet white pages, big bold titles, thin lines, and color that says what something is. This file replaces the direction chosen in `design-demos/direction-approved.md` where the app has moved on. iOS, Mac and Android follow the same rules; colors and sizes live in `Porridge/Design/Theme.swift` and `android/.../ui/Theme.kt`.

## Color

| Color | Value | Used for |
| --- | --- | --- |
| Sky | `#24B4E9`, text `#0B79A8` | The plus button, selection, toggles, the mic button, notes and their date headers |
| Navy | `#1F3667`, dark `#B0C4EC` | Titles of notes, icons on bars and buttons, symbols on sky, orange and green, meetings, Archive, pins |
| Green | `#29BD80`, text `#0F8A5A` | Check boxes in summaries |
| Violet | `#7C5CD6`, dark `#9B82E8` | Buckets (projects in the code) |
| Orange | `#FA8F24`, text `#B55D00` | Saved links |
| Red | System red, text `#D93025`, dark `#FF6B60` | Recently Deleted, everything that deletes, and recording: the stop button and the mic while it runs |

Speakers have their own sequence of colors (`speakerColors`), starting with sky and orange. It says who is talking and nothing about the kind of thing.

Every kind of thing keeps its color everywhere: in the list icon, its section header and its page.

Sky, orange and green are for surfaces. As text or a symbol on a white page they use the darker "text" value, which reaches 4.5:1 (green 3:1, used only bold). Symbols on a full fill of them are navy, never white. In dark mode the bright values are the readable ones. The Apple platforms also have a variant for Increase Contrast.

## Layout

- **Pages** are white (near black in dark mode) with hairlines as separators. Note pages scroll as a whole, head included, on iPhone and Android. The Mac keeps the head of a note in place.
- **Moving between pages:** on iPhone, iPad and Android pages slide in and out as the system does it, and going back follows the finger where the platform offers that. The Mac sidebar changes in place.
- **Section headers** are small and bold in the color of their kind, with a line below. Archive and Recently Deleted are tappable headers with a chevron at the bottom of the home list.
- **Bottom bar:** chat and search as white round buttons with navy icons on the left, the blue plus on the right. Each opens a page of its own: the search with its field on top, the chat with its field at the bottom.
- **Chat:** a page of its own that asks the buckets, with its field at the bottom instead of the round buttons. A chat is about all buckets or one (a pill on top says which; a new chat can choose), answers name the notes they come from as pills, and chats are kept: the bar of the page has the list of chats and a new chat.
- **Plus menu:** what can be created (Bucket, Link, Meeting, Note), each in the color of its kind.
- **Import menu:** a button in the bar beside Settings, on the home list and in a bucket: Import Audio, Import Plaud once signed in, Photo or File.
- **Live Activity and notification:** the running meeting with its clock, pause and stop. Navy on the light Lock Screen card, white on the black Dynamic Island.
- **Inbox:** rows like in every list. A bucket is chosen in the long press of a row; only a suggested bucket shows as a pill under it.
- **Home list:** the Inbox with one entry of its name, then the buckets: the pinned ones and the 5 latest others; "More" unfolds the rest in place.
- **Row icons:** a rounded square as high as the two lines of the row, in the color of the kind. A pinned entry wears a small navy pin badge on the top right of the icon's border.
- **Kinds:** meetings, notes, links, images and files. Images and files are two kinds that behave alike. A bucket's filter pills show only the kinds it holds.
- **Check boxes:** green squares for tasks inside summaries. Circles only for checklists you write in a note.

## Controls

- **Sheets:** "Cancel" on the left when closing throws work away, "Done" on the right when nothing is lost.
- **Deleting for good always asks first.** Moving something to Recently Deleted does not, because it can come back.
- **Main buttons** are a wash of their color with a navy label. Disabled buttons fade; destructive ones turn red.
- **Summary models** are one list, on-device and cloud alike, with one default. Adding one happens in a sheet; a meeting chooses its model and template in one sheet, and that choice holds for this summary only.
- **Menus** are grouped by a line: the note and its summary, the recording, what deletes.
- **Native controls first.** Custom ones only where the system has no equivalent.
- **Wording:** English Title Case for buttons and titles, "…" without a space before it.
