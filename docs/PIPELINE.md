# LabScribe AI — Analysis Pipeline

How a recording becomes a transcript, a summary, and tasks — and the
rules that keep the app honest about where every word came from.

## 1. Transcript sources (in priority order)

1. **On-device Whisper** (`whisper_ggml`, all release platforms).
   Mobile recordings save as compact AAC (converted automatically);
   desktop saves 16 kHz mono WAV directly. Linux captures through the
   FFmpeg CLI (PulseAudio/PipeWire, direct ALSA fallback) because the
   `record` package's Linux backend shells out to an external `fmedia`
   binary nothing ships; if neither FFmpeg nor fmedia exists, recording is
   refused with an install dialog instead of a raw ProcessException.
   Both paths transcribe locally with a biomedical vocabulary bias. The
   model downloads once on first use and stays cached; later runs are
   fully offline. Long recordings split into sequential parts with
   rolling context. Non-WAV imports convert via the bundled FFmpeg on
   Android/macOS; on Windows/Linux they need FFmpeg on PATH (clear error
   otherwise). After a stop, the WAV's peak level is checked — a file
   full of digital silence triggers a "pick another input device"
   warning rather than a mysteriously empty transcript.
2. **Pasted or imported text** is analyzed directly (no audio step).
3. There is no sample-data path. Failures throw with actionable messages;
   silent audio yields an empty transcript, and synthesis refuses empty
   input instead of inventing content.

## 2. Live captions (HyperOS-style subtitles)

`LiveCaptionService` captures 16 kHz mono PCM once and tees the same byte
stream into (a) a `WavWriter` on disk and (b) the Whisper streaming session
(`WhisperController.transcribeLive`). While recording, progressively
refined — filler-cleaned — partials roll through the "AI subtitles" strip;
stopping finalizes the engine text, patches the WAV header, and stores the
draft transcript immediately, so Analysis can run on real segment
timestamps afterwards. Live mode degrades to plain file recording on any
failure (missing model, unusable microphone) — the meeting is never lost
because a subtitle feature broke.

## 3. Honesty rules (enforced in code)

- `transcribeAudio` runs on-device Whisper and throws with an
  actionable message on failure (missing file, missing FFmpeg for
  non-WAV imports, empty result). Nothing is ever substituted.
- `processSessionIntelligence` refuses empty transcripts instead of
  inventing content.
- `_executeAiPipeline` routes every failure to a retry dialog.
  Dismissing leaves existing audio, notes, and transcripts untouched.

## 4. On-device transcription (`whisper_ggml` 2.x)

Adopted for all release platforms (Android, iOS, Linux, macOS, Windows).
Batch passes use the low-level `Whisper.transcribe(TranscribeRequest,
modelPath:)` API deliberately: `WhisperController.transcribe` catches
every native error and returns `null`, discarding the real reason
("WAV file must be 16 kHz", "failed to load model") — the low-level call
rethrows it, and known messages are expanded into install/re-record
instructions (`_engineErrorHint`). `WhisperModel.tiny/base/small`
(multilingual variants; English-only `*En` models are avoided so Hinglish
keeps working). `lang` maps from the app language selector (`en` → `en`,
`hi` → `hi`, otherwise `auto`).

Before inference, `WavProbe` repairs RIFF/data sizes left dangling by an
interrupted recorder and validates the format, converting only when
FFmpeg exists (precise error when it does not). Requests pass
`suppressNonSpeechTokens` (drops music/noise/silence markers) and
`keepModelLoaded` (parks the weights after each chunk so long meetings
and live captions reuse them instead of reloading for seconds).
Segment timestamps are returned when available and ground speaker turns
and playback seek in the real recording clock — index ranges from the
model when the transcript is short, word-count estimates only as a last
resort. `WhisperModel.modelUri`-based downloads go through the app with
real MB progress and size verification — never trusting an invisible
auto-download. A silence warm-up then proves inference works (a failure
leaves the model *un*-warmed instead of masking it) before any meeting
audio is touched. Synthesis, Q&A, and translation use a keyless hosted
open model (`MeetingIntelligenceService.llmBaseUrl`).

## 5. Model sizes (Engine settings)

| Model | Download | RAM | Best for |
| :--- | :--- | :--- | :--- |
| Tiny | ~75 MB | ~150 MB | Quick notes, older devices |
| Base (default) | ~150 MB | ~250 MB | Balanced meetings and talks |
| Small | ~460 MB | ~500 MB | Best accuracy, newer phones/desktops |

## 6. Session types

`MeetingSession.kind` (`meeting`, `journalClub`, `seminar`, `lecture`)
retargets the synthesis prompt: journal club emphasizes paper critique
and required revisions, seminar the takeaways and open questions, lecture
key concepts and assigned work, lab meeting decisions and owners. The
choice persists (schema v6) and is picked from chips in the recording
panel before or during a session.

## 7. Development notes

- Dart `num.clamp()` returns `num`: always follow with `.toInt()` /
  `.toDouble()` when the target is typed (`flex:`, slider `value:`,
  list indices, `Map<String, int>` writes). The Linux release compiler
  rejects implicit narrowing.
- `speechTurns` drive the transcript view, talk-time math, and seek.
  Keep them sorted and preserve `speakerId` stability so renames cascade.
- `SessionRepository` schema is at v6 (`kind`, `chatHistoryJson`); follow
  the `liveNotesJson`-style column pattern for any future session fields,
  with an `if (oldVersion < N)` upgrade guard.
