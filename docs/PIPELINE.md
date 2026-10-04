# LabScribe AI — Analysis Pipeline

How a recording becomes a transcript, a summary, and tasks — and the
rules that keep the app honest about where every word came from.

## 1. Transcript sources (in priority order)

1. **Configured transcription endpoint** (`Settings → Transcription`).
   Examples: Groq `whisper-large-v3`, OpenAI `whisper-1`, or a local
   Faster-Whisper server. Supports chunked uploads above ~24 MB with a
   biomedical vocabulary prompt and rolling context.
2. **Built-in sample** — only when the user explicitly chooses
   “Use sample” / “View sample”. The UI then shows a `DemoBanner`
   (“Sample data — a built-in example, not your recording”) on the
   Overview and Transcript tabs until new real input arrives.

There is no third source. In particular, endpoint failures are **never**
silently replaced with sample text.

## 2. Honesty rules (enforced in code)

- `transcribeAudio(allowDemoSample: false)` (the default) throws
  `StateError` when no endpoint is configured, and rethrows endpoint
  failures wrapped with context. Sample text requires
  `allowDemoSample: true`, which only the setup wizard, the error
  dialog, and the demo banner can pass.
- `processSessionIntelligence` follows the same rule for the LLM step.
- `_executeAiPipeline` routes every failure to `_showPipelineErrorDialog`,
  which offers Retry / View sample / Settings. Dismissing leaves existing
  audio and notes untouched.
- `_isDemoContent` marks the visible session; starting a recording,
  importing audio, loading a session, or editing the transcript clears it.

## 3. Why no on-device transcription plugin

Evaluated and deliberately not adopted:

- `speech_to_text` (the standard Flutter plugin) has **no Linux
  implementation**, and this project ships a Linux `.deb` built in CI —
  adding the dependency risks that build for zero Linux benefit.
- On **Android, recording audio and running speech recognition at the
  same time conflict** over the microphone (documented plugin
  limitation); live captions during recording would be unreliable on
  the primary mobile platform.
- OS recognizers are tuned for dictation/commands, not multi-speaker
  biomedical discourse with gene/drug casing requirements.

If this changes, the seam is `MeetingIntelligenceService.transcribeAudio`:
add a new source branch ahead of the endpoint call and keep the
`allowDemoSample` gate unchanged.

## 4. Endpoint setup paths (what the wizard offers)

| Path | Transcription | LLM | Effort |
| :--- | :--- | :--- | :--- |
| Groq free key | `whisper-large-v3` | `llama-3.3-70b-versatile` | Paste key from console.groq.com (~2 min) |
| Local server | Faster-Whisper on `:8000` | Ollama / vLLM | Run `scripts/setup_local_ai.sh` |
| OpenAI key | `whisper-1` | `gpt-4o-mini` | Paid key |
| Sample data | Built-in example | Built-in example | None; always labeled |

## 5. Health checks

`checkTranscriptionHealth()` / `checkLlmHealth()` probe `GET /models`
on the configured bases. They are approximations (not transcription
trials) used only for the red/amber/green dots in the recording deck.
`false` means “unconfigured or unreachable”, never a diagnosis.

## 6. Development notes

- Dart `num.clamp()` returns `num`: always follow with `.toInt()` /
  `.toDouble()` when the target is typed (`flex:`, slider `value:`,
  list indices, `Map<String, int>` writes). The Linux release compiler
  rejects implicit narrowing.
- `speechTurns` drive the transcript view, talk-time math, and seek.
  Keep them sorted and preserve `speakerId` stability so renames cascade.
- `SessionRepository` schema is at v5; adding a persisted demo flag
  would require a v6 migration (`liveNotesJson`-style pattern).
