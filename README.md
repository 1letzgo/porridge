# Porridge

Lokale KI-Transkription für Meetings und Notizen (iPhone & iPad, später Mac). SwiftUI, SwiftData + CloudKit, FluidAudio (Parakeet TDT v3 0.6B, pyannote).

## Setup

```sh
brew install xcodegen
xcodegen generate
open Porridge.xcodeproj
```

Team `699G2QY959`, Bundle-ID `de.letzgo.porridge`, iCloud-Container `iCloud.de.letzgo.porridge` (im Developer-Portal anlegen bzw. per Automatic Signing). Minimum iOS 18.

## Aufbau

| Pfad | Inhalt |
| --- | --- |
| `Porridge/Models` | `Meeting`, `Note` (SwiftData, CloudKit-kompatibel), Transkript-Typen |
| `Porridge/Services/AudioRecorder` | AVAudioEngine-Aufnahme → AAC, bis zu 2 Kanäle |
| `Porridge/Services/AudioPreprocessor` | Mono-16-kHz-Mix für ASR + Energie pro Kanal |
| `Porridge/Services/TranscriptionEngine` | FluidAudio: Parakeet v3 + Offline-Diarisierung |
| `Porridge/Services/SpeakerAssigner` | Wörter → Sprecher (per Kanal oder per Diarisierung), Segmentierung |
| `Porridge/Services/ProcessingService` | Serielle Verarbeitungs-Queue, Wiederaufnahme nach Absturz |
| `Porridge/Services/SummaryService` | Zusammenfassung: lokal (Qwen3 4B per MLX) oder mit eigenem Key |
| `Porridge/Services/LocalLLM` | Lokales Modell (MLX Swift LM), Download von Hugging Face |
| `Porridge/Services/AIProvider`, `CloudLLM` | OpenRouter, OpenAI, Anthropic, Google Gemini, Mistral, eigener OpenAI-kompatibler Server |

## Sprecher

- **DJI Mic (Stereo-Modus) / 2-Kanal-USB-Mikro**: Ein Transkript aus dem Mono-Mix, jedes Wort wird dem Kanal mit der höheren (normalisierten) Energie zugeordnet. So gibt es keine doppelten Texte durch Übersprechen. Namen lassen sich bei der Aufnahme und danach vergeben.
- **1 Kanal**: Sprecher werden per pyannote-Diarisierung (FluidAudio `OfflineDiarizerManager`) erkannt und als „Sprecher 1/2/…“ angelegt – umbenennbar, Segmente per Kontextmenü umhängbar. Abschaltbar in den Einstellungen.

## Notizen

- **Text**: Markdown in `Note.text` (Überschriften `#`–`###`, `**fett**`, `*kursiv*`, `~~durchgestrichen~~`, `` `Code` ``, Listen, Nummerierung, Checklisten `- [ ]`, Zitate `>`, Codeblöcke). `MarkdownEditor` (UITextView) formatiert live, eine Leiste über der Tastatur setzt Formate, Return setzt Listen fort, Checkboxen sind antippbar, „In Notiz suchen“ über das Menü.
- **Tags**: `#wort` im Text, kein eigenes Feld; Tag-Liste und Filter in der Seitenleiste.
- **Ordner**: `NoteFolder` (verschachtelt über `parentID`), `Note.folderID`; nil = Ordner „Notizen“.
- **Organisation**: Anpinnen, Suche, Sortierung (Bearbeitet/Erstellt/Titel), Gruppen nach Datum.
- **Papierkorb**: „Zuletzt gelöscht“ (`Note.deletedAt`), nach 30 Tagen endgültig gelöscht (`NoteStore`).
- Nur iOS; für den Mac fehlen noch Editor-Fallback (`MarkdownEditor` ist UIKit) und Menü-Label.

## Sync

Texte, Sprecher, Zusammenfassungen: SwiftData → privater CloudKit-Container. Audio bleibt lokal auf dem aufnehmenden Gerät (`Application Support/Recordings`). Die API-Keys liegen im iCloud-Schlüsselbund.

## Mac-App

Die Services sind plattformneutral gehalten (`#if os(iOS)` nur um `AVAudioSession`/UIKit). Für macOS ein zweites Target in `project.yml` anlegen, das dieselben Quellen nutzt.
