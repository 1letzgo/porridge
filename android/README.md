# Porridge for Android

Kotlin/Compose port of the iOS app (same recipe as abstand and stede: a parallel native app that mirrors the
iOS code file by file, no KMP). **iOS is the source of truth for logic**: when porting, read the Swift file
first and name it in the KDoc (`/** iOS: NoteStore */`). Strings in the UI are English like iOS; comments are German.

What is shared 1:1:

- **Version:** `versionName` = `MARKETING_VERSION` from `../project.yml` (same as the Mac release);
  `versionCode` = `git rev-list --count HEAD`.
- **Preference keys:** `data/Prefs.kt` `Keys` = the iOS `UserDefaults` keys.
- **Data:** Room entities with the field names of the SwiftData models; `speakersData`/`segmentsData` hold the
  same JSON as iOS. No sync: backup and restore as a file instead of CloudKit.
- **Golden files:** `../shared/fixtures/` (cases both platforms check; Android reads them as test resources).

## Build

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
./gradlew assembleSideloadDebug testSideloadDebugUnitTest
./gradlew assembleSideloadRelease   # signed APK
```

Build output lives outside iCloud (`~/Library/Caches/porridge-android/<checkout hash>`), one directory per
checkout so git worktrees don't collide.

Signing: `~/Library/Application Support/porridge-signing/keystore.properties` (`storeFile`, `storePassword`,
`keyAlias`, `keyPassword`), used by debug and release so they install over each other. **Never replace this key**:
installed apps refuse updates signed with another one. Keep a backup of `porridge.jks` and the properties file.

## Releases (GitHub, in-app update)

`scripts/release-android.sh` (like `scripts/release-mac.sh`): tag `android-v<version>`, asset
`Porridge-android-<version>.apk` in the public repo `1letzgo/porridge`. It refuses a dirty tree and an existing tag,
runs the unit tests, builds the signed sideload APK, tags, pushes, creates the release and checks the uploaded
digest. `--dry-run` builds only.

The app (`data/AppUpdate.kt`, `sideload` flavor only, not when installed from Google Play) reads these releases at
launch (at most every 6 h) and from "Check for Updates", compares versions number by number like the Mac
(`PorridgeMac/Update/AppUpdate.swift`), downloads the APK, verifies GitHub's SHA-256 digest and hands it to the
package installer.

| Flavor | Distribution |
|---|---|
| `sideload` | signed APK from GitHub releases, in-app update |
| `play` | Google Play (prepared, no own update check) |

## Layout (`app/src/main/java/de/letzgo/porridge/`)

| Android | iOS |
|---|---|
| `PorridgeApplication.kt`, `MainActivity.kt` | `App/PorridgeApp.swift` |
| `data/Prefs.kt` (`Keys`, `Prefs`, `SummaryBilling`, `SpeechEngine`) | `Services/AppSettings.swift`, `UserDefaults` |
| `data/SecureStore.kt` | `Services/Keychain.swift` (device only, no iCloud Keychain) |
| `data/AppUpdate.kt`, `ui/AppUpdateUi.kt` | `PorridgeMac/Update/AppUpdate.swift` (+ APK install like stede) |
| `data/Net.kt`, `data/Json.kt` | `URLSession.shared`, `JSONDecoder` |
| `model/Note.kt`, `model/NoteText.kt` | `Models/Note.swift` (`Note`, `NoteText`) |
| `model/NoteFolder.kt` | `Models/NoteFolder.swift` (`NoteFolder`, `NoteScope`, `tree`, `path`, `subtreeIDs`) |
| `model/VoiceProfile.kt` | `Models/VoiceProfile.swift`, `VoiceMath` |
| `model/ActionItem.kt` | `Models/ActionItem.swift` |
| `model/Transcript.kt` | `Models/Transcript.swift` |
| `store/PorridgeDatabase.kt`, `store/Daos.kt` | `App/AppContainer.swift` (SwiftData container); Room schemas in `app/schemas/` |
| `store/NoteStore.kt`, `store/AudioStore.kt`, `store/NoteMerger.kt` | `Services/NoteStore.swift`, `AudioStore.swift`, `NoteMerger.swift` |
| `store/ActionItemStore.kt`, `logic/ActionItemsLogic.kt` | `Services/ActionItems.swift` |
| `logic/ChatRetrieval.kt`, `logic/ChatPrompt.kt`, `cloud/ChatStore.kt` | `Services/ChatService.swift`, `ChunkRanking.swift` |
| `logic/SpeakerAssigner.kt`, `logic/Paragraphs.kt`, `logic/SummaryLogic.kt`, `logic/NoteMergeLogic.kt`, `logic/VoiceProfileLogic.kt`, `logic/LanguageDetect.kt` | the matching `Services/*.swift` (pure parts) |
| `logic/editor/` (`NoteBlock`, `NoteMarkdown`, `NoteEditorEngine`, `EditorBuffer`) | `Views/Notes/NoteBlocks.swift`, `NoteMarkdown.swift`, `NoteTextCoordinator` in `NoteTextView.swift` |
| `index/NoteIndex.kt` | `Services/NoteIndex.swift` (CBOR file instead of plist) |
| `cloud/` (`AIProvider`, `CloudLLM`, `SummaryService`) | `Services/AIProvider.swift`, `CloudLLM.swift`, `SummaryService.swift` |
| `ml/SpeechModel.kt`, `ml/Diarizer.kt`, `ml/VoiceProfiles.kt` | `Services/TranscriptionEngine.swift` (Parakeet via sherpa-onnx instead of FluidAudio) |
| `ml/LocalLLM.kt`, `ml/TextEmbedder.kt`, `ml/ModelManager.kt`, `ml/ModelCatalog.kt` | `Services/LocalLLM.swift`, `TextEmbedder.swift`, `ModelManager.swift` (llama.cpp instead of MLX) |
| `audio/` (`AudioRecorder`, `AudioPreprocessor`, `LiveTranscriber`, `RecordingService`, `InlineDictation`) | `Services/AudioRecorder.swift`, `AudioPreprocessor.swift`, `LiveTranscriber.swift`, `InlineDictation.swift`; the foreground service replaces the Live Activity |
| `processing/ProcessingService.kt` | `Services/ProcessingService.swift` |
| `plaud/` | `Services/Plaud/*.swift` (BLE with a serial GATT queue, own ChaCha20-Poly1305 for API 26) |
| `data/Backup.kt` | (Android only) backup and restore as a zip instead of CloudKit |
| `ui/Theme.kt`, `ui/components/` | `Design/` (brand colors, "Things 3" direction, `ChromeBar`, `TabSwitcher`) |
| `ui/AppRoot.kt` | `App/RootView.swift` (screen stack) |
| `ui/notes/` | `Views/Notes/` (`NotesView`, `NoteDetailView`, `NoteBodyEditor`, `NoteTextView`, sheets) |
| `ui/tasks/` | `Views/Tasks/TasksPane.swift`, `TaskDetailView.swift` |
| `ui/chat/`, `ui/recording/`, `ui/settings/`, `ui/onboarding/`, `ui/plaud/` | the matching `Views/*` |

## Port status

Ported with full parity to the iOS state of 30 October 2026, including the TextKit editor, the search index with
z-score chat ranking, and tasks as items of their own. 62 unit tests.

Checked in the emulator: onboarding, list, plus menu, editor (lists, checklists, headings, tags), Parakeet download,
audio import with transcription and speakers, playback, tasks with their own page, settings.

Not checked yet: the local LLM on a real phone (needs 8 GB RAM for Qwen3 4B), Plaud with a real recorder over
Bluetooth, a stereo USB microphone, the update check end to end.

Not ported: Mac dictation, Live Activity (a foreground notification instead), Apple's speech model, CloudKit.
