# Porridge design

The look follows Things 3: quiet white pages, big bold titles, thin lines, and color that says what something is. This file replaces the direction chosen in `design-demos/direction-approved.md` where the app has moved on. iOS, Mac and Android follow the same rules; colors and sizes live in `Porridge/Design/Theme.swift` and `android/.../ui/Theme.kt`.

## Color

| Color | Value | Used for |
| --- | --- | --- |
| Sky | `#24B4E9` | The plus button, selection, toggles, the mic button, notes and their date headers |
| Navy | `#1F3667`, dark `#B0C4EC` | Titles of notes and tasks, icons on bars and buttons, meetings, Archive |
| Green | `#29BD80` | Tasks and their check boxes, Done |
| Violet | `#7C5CD6` | Projects |
| Orange | `#FA8F24` | Saved links |
| Red | `#E63F3D` for chat, system red for danger | Chat; Recently Deleted and everything that deletes |

Every kind of thing keeps its color everywhere: in the list icon, its section header and its page.

## Layout

- **Pages** are white (near black in dark mode) with hairlines as separators. Note and task pages scroll as a whole, head included, on iPhone and Android. The Mac keeps the head of a note in place.
- **Section headers** are small and bold in the color of their kind, with a line below. Done, Archive and Recently Deleted are tappable headers with a chevron at the bottom of the home list.
- **Bottom bar:** filter, search and chat as white round buttons with navy icons, the blue plus on the right. An active filter fills its button with the color of the kind.
- **Home list:** at most 25 elements and 5 unpinned projects; "More" unfolds the rest in place.
- **Check boxes:** green squares for tasks, also inside summaries. Circles only for checklists you write in a note.

## Controls

- **Sheets:** "Cancel" on the left when closing throws work away, "Done" on the right when nothing is lost.
- **Deleting for good always asks first.** Moving something to Recently Deleted does not, because it can come back.
- **Main buttons** are a wash of their color with a navy label. Disabled buttons fade; destructive ones turn red.
- **Native controls first.** Custom ones only where the system has no equivalent.
- **Wording:** English Title Case for buttons and titles, "…" without a space before it.
