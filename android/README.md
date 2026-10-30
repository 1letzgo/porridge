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
| `store/PorridgeDatabase.kt`, `store/Daos.kt` | `App/AppContainer.swift` (SwiftData container) |
| `store/NoteStore.kt` | `Services/NoteStore.swift` |
| `store/AudioStore.kt` | `Services/AudioStore.swift` |
| `ui/Theme.kt` | `Design/` (Brand colors, "Things 3" direction) |
| `ui/AppRoot.kt` | `Views/Notes/NotesView.swift` (placeholder until the notes screens are ported) |

## Port status

Phase 1 (this): Gradle, signing, data layer, update check, release script. Next, in parallel: audio and recording
service, on-device ML (sherpa-onnx Parakeet v3 + diarization + sentence vectors, llama.cpp), pure logic with
fixtures (speaker assignment, Markdown/editor rules, chat ranking), cloud providers, Plaud, UI screens, search index.
Not ported: Mac dictation, Live Activity (a foreground notification instead), Apple's speech model, CloudKit.
