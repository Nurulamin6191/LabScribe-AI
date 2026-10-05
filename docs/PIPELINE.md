# LabScribe AI — Analysis Pipeline

How a recording becomes a transcript, a summary, and tasks — and the
rules that keep the app honest about where every word came from.

## 1. Transcript sources (in priority order)

1. **On-device Whisper** (`whisper_ggml`, all release platforms).
   Recordings are saved as 16 kHz mono WAV, transcribed locally with a
   biomedical vocabulary bias. The model downloads once on first use and
   stays cached; later runs are fully offline. Long recordings split into
   sequential parts with rolling context. Non-WAV imports convert via the
   bundled FFmpeg on Android/macOS; on Windows/Linux they need FFmpeg on
   PATH (clear error otherwise).
2. **Pasted or imported text** is analyzed directly (no audio step).
3. There is no sample-data path. Failures throw with actionable messages;
   silent audio yields an empty transcript, and synthesis refuses empty
   input instead of inventing content.

## 2. Honesty rules (enforced in code)

- `transcribeAudio` runs on-device Whisper and throws with an
  actionable message on failure (missing file, missing FFmpeg for
  non-WAV imports, empty result). Nothing is ever substituted.
- `processSessionIntelligence` refuses empty transcripts instead of
  inventing content.
- `_executeAiPipeline` routes every failure to a retry dialog.
  Dismissing leaves existing audio, notes, and transcripts untouched.

## 3. On-device transcription (`whisper_ggml` 2.x)

Adopted for all release platforms (Android, iOS, Linux, macOS, Windows).
Only the long-stable API surface is used: `WhisperController`,
`transcribe(model:, audioPath:, lang:, initialPrompt:, withSegments:,
onProgress:)`, `WhisperModel.modelUri`, `getPath`, `WhisperModel.tiny/base/small` (multilingual variants;
English-only `*En` models are avoided so Hinglish keeps working).
`lang` maps from the app language selector (`en` → `en`, `hi` → `hi`,
otherwise `auto`). Model files are downloaded by the app itself from the
plugin's own HuggingFace URLs (`modelUri`) into the plugin's own path
(`getPath`) with real MB progress and size verification — never trusting
an invisible auto-download. A silence warm-up then proves inference works
before any meeting audio is touched. Synthesis, Q&A, and translation use
a keyless hosted open model (`MeetingIntelligenceService.llmBaseUrl`).

## 4. Model sizes (Engine settings)

| Model | Download | RAM | Best for |
| :--- | :--- | :--- | :--- |
| Tiny | ~75 MB | ~150 MB | Quick notes, older devices |
| Base (default) | ~150 MB | ~250 MB | Balanced meetings and talks |
| Small | ~460 MB | ~500 MB | Best accuracy, newer phones/desktops |

## 5. Development notes

- Dart `num.clamp()` returns `num`: always follow with `.toInt()` /
  `.toDouble()` when the target is typed (`flex:`, slider `value:`,
  list indices, `Map<String, int>` writes). The Linux release compiler
  rejects implicit narrowing.
- `speechTurns` drive the transcript view, talk-time math, and seek.
  Keep them sorted and preserve `speakerId` stability so renames cascade.
- `SessionRepository` schema is at v5; follow the `liveNotesJson`-style
  column pattern for any future session fields.
