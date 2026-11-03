<p align="center">
  <img src="Porridge/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="110" alt="Porridge icon">
</p>

<h1 align="center">Porridge</h1>

<p align="center">
  <strong>Notes, meetings and dictation, transcribed on your device.</strong><br>
  For iPhone, iPad, Mac and Android.
</p>

<p align="center">
  <a href="https://github.com/1letzgo/porridge/releases?q=mac-v"><img alt="Mac release" src="https://img.shields.io/github/v/release/1letzgo/porridge?filter=mac-v*&label=Mac&color=24B4E9"></a>
  <a href="https://github.com/1letzgo/porridge/releases?q=android-v"><img alt="Android release" src="https://img.shields.io/github/v/release/1letzgo/porridge?filter=android-v*&label=Android&color=29BD80"></a>
</p>

<p align="center">
  <img src="docs/screenshots/home.png" width="240" alt="Home list with tasks, projects and notes">
  <img src="docs/screenshots/summary.png" width="240" alt="A meeting with its summary">
  <img src="docs/screenshots/transcript.png" width="240" alt="A transcript with speakers">
</p>

Porridge records what is said in a meeting, writes it down with speaker names and turns it into a summary with tasks. Speech recognition runs on your device and summaries can too, so a recording does not have to leave it. Notes, tasks, saved links and projects live in one quiet list.

## What it does

- **Meetings:** Record a meeting and get a transcript with speakers. Porridge recognizes voices it has learned. A two-channel microphone assigns each channel to one person.
- **Summaries with templates:** Choose General, One-on-One, Customer Call, Lecture or your own template each time. Tasks from a summary land in your task list as suggestions.
- **Dictation:** Dictate into any note. On the Mac, a global shortcut types into whatever app you are using.
- **Notes:** Headings, lists and checklists as you type, stored as Markdown.
- **Links:** Share a page to Porridge to save its text and summarize it.
- **Projects and tasks:** Keep notes, meetings, links and tasks together, with pinned projects at the top.
- **Search and chat:** Search everything, or ask your notes a question and get an answer that names its sources.
- **Sync:** iCloud on Apple devices, or your own Nextcloud across all platforms.
- **Plaud import:** Bring in recordings from a Plaud recorder.

<p align="center">
  <img src="docs/screenshots/search.png" width="240" alt="Search across everything">
  <img src="docs/screenshots/dark.png" width="240" alt="Dark mode">
  <img src="docs/screenshots/android.png" width="240" alt="The Android app">
</p>

## On your device

| | Runs locally | Optional |
| --- | --- | --- |
| **Speech** | Parakeet TDT v3 (25 European languages), Apple Speech on Apple devices | |
| **Speakers** | pyannote | |
| **Summaries and chat** | Qwen3 on all platforms, Apple Intelligence on Apple devices | Your own key for OpenRouter, OpenAI, Anthropic, Google, Mistral, Groq or a compatible server |

Models download once and then work offline. With iCloud, audio stays on the device that recorded it; with Nextcloud, recordings sync too.

## Get it

| Platform | How | Needs |
| --- | --- | --- |
| **Mac** | [Latest release](https://github.com/1letzgo/porridge/releases?q=mac-v). Not notarized yet: open it the first time with right-click → Open. | macOS 15 |
| **Android** | [Latest APK](https://github.com/1letzgo/porridge/releases?q=android-v). Later versions come through the in-app update. | Android 8 |
| **iPhone and iPad** | Build from source, see below. | iOS 18 |

## Build from source

```sh
brew install xcodegen
xcodegen generate
open Porridge.xcodeproj
```

Use the `Porridge` scheme for iPhone and iPad and `PorridgeMac` for the Mac. You need your own Apple team and iCloud container for signing. For Android, see [android/README.md](android/README.md).

## Project layout

| Path | Content |
| --- | --- |
| `Porridge/Models` | SwiftData models |
| `Porridge/Services` | Recording, transcription, summaries, chat, sync, Plaud |
| `Porridge/Views`, `Porridge/Design` | SwiftUI views and the shared look |
| `PorridgeMac` | Mac app: dictation shortcut, menu bar, updates |
| `PorridgeWidgets`, `PorridgeShare` | Widgets, Live Activity and the share extension |
| `android` | Native Android app in Kotlin and Compose |
| `scripts` | Release scripts for Mac, Android and TestFlight |

The look and its rules are written down in [DESIGN.md](DESIGN.md).
