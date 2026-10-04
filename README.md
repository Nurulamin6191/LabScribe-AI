# LabScribe AI — Scientific Meeting & Research Companion

[![Releases](https://img.shields.io/badge/Releases-APK%20%7C%20DEB%20%7C%20EXE-blue?logo=github)](https://github.com/Nurulamin6191/LabScribe-AI/releases)
[![Platforms](https://img.shields.io/badge/Platforms-Android%20%7C%20Windows%20%7C%20Linux-brightgreen)](#-download-standalone-installers)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

**LabScribe AI** is a cross-platform companion for lab seminars, journal clubs, tumor boards, and thesis defenses. It records audio, produces transcripts via a configurable transcription endpoint, organizes summaries, bench tasks, speaker-labeled turns, and literature references, and supports export to Markdown, ELN JSON, and BibTeX.

> Scope note: outputs are model-generated and heuristic. Verify gene names, doses, statistics, speaker labels, and citations before using them in protocols, manuscripts, or clinical documentation.

---

## Download Standalone Installers

No Flutter, Git, or command-line setup required for the packaged builds:

| Operating System | Standalone Package | How to Install |
| :--- | :--- | :--- |
| **Android Phone / Tablet** | [**LabScribe-AI-Universal.apk**](https://github.com/Nurulamin6191/LabScribe-AI/releases/latest) | Tap to install |
| **Linux (Ubuntu / Debian / Mint)** | [**labscribe_1.0.0_amd64.deb**](https://github.com/Nurulamin6191/LabScribe-AI/releases/latest) | Double-click to install (adds desktop entry) |
| **Windows 10 / 11 (64-bit)** | [**LabScribe-AI-Windows-x64.zip**](https://github.com/Nurulamin6191/LabScribe-AI/releases/latest) | Extract and run `labscribe.exe` |

---

## Key Features

- **Speaker-labeled turns**: groups transcript segments by detected speaker flow, with manual rename that updates turns and task attributions, plus tap-to-seek playback where audio is available.
- **Call audio import**: import existing recordings (`.m4a`, `.mp3`, `.wav`, `.opus`) from conferencing tools for transcription and analysis. Loopback/monitor capture depends on OS audio setup.
- **Long-audio handling**: files above the transcription payload limit are processed in sequential chunks with rolling context.
- **Redaction helper**: optional pattern-based masking for common identifier formats (e.g. MRN-like labels, DOB-like phrases, phone/email patterns). Review output before sharing. This is not a certification of de-identification.
- **Biomedical transcription prompts**: transcription requests include a domain vocabulary prompt covering genes, therapeutics, assays, and statistics. Verify casing and terms in the transcript editor.
- **Reference hashes**: SHA-256 hashes for audio files and transcript text are stored with the session and included in exports for reference. This is not a compliance certification.
- **Noise controls**: uses platform noise suppression, echo cancellation, and auto-gain options exposed by the recorder plugin where supported.
- **Bibliography export (.bib)**: formats saved citations for reference managers and LaTeX.
- **Notebook and ELN export**: generates Markdown notes and structured JSON for ELN import.
- **Long-transcript summarization**: transcripts above ~5,000 words are summarized in overlapping sections before a final synthesis.

---

## Meeting Workflow Support

| Capability | Implementation | Notes |
| :--- | :--- | :--- |
| **Speaker turns** | Dialogue-flow segmentation + editable labels | Verify labels before export |
| **Call import** | File picker for `.m4a`/`.opus`/etc. | Depends on files exported by meeting apps |
| **Compact dock** | Narrow card layout toggled from the AppBar | Useful alongside slides or meeting windows |
| **Quick tags** | `Action Item`, `Hypothesis`, `Result`, `Question` bookmarks | Timestamped to the recording timer |
| **Exit confirm** | `PopScope` guard during active recording | Helps avoid accidental navigation |
| **Microphone selection** | `AudioRecorder.listInputDevices()` | Device list depends on OS permissions |
| **Live notes stream** | Chronological list in the recording deck | Stored with the session |
| **Responsive layout** | Desktop: rail + deck + content; Mobile: bottom bar | See `recorder_view.dart` |

---

## In-App Reference Tools

These reduce context switching; network features require connectivity:

1. **PubMed reader**:
   - Queries NCBI E-Utilities (`esearch`, `esummary`).
   - Shows title, authors, journal, DOI, PMID, and available abstract text in-app.
   - Copies a short citation string.
2. **Built-in term atlas**:
   - Local map of selected oncology drugs, genes, assays, and statistics terms.
   - Used before network lookups; edit entries in `public_api_service.dart`.
3. **PubChem and PubMed search**:
   - Search bar for compounds/genes and papers/PMIDs during review.
4. **Figure viewer**:
   - `InteractiveViewer` pinch-to-zoom for attached images.
5. **Markdown preview**:
   - `MarkdownBody` preview of the generated notebook before export.

---

## Architecture

```mermaid
flowchart TD
    subgraph AudioHardware [Audio Ingestion]
        MIC[Microphone / USB Input] -->|Selected via InputDevice| REC[AAC-LC Recorder]
        VIRT[Meeting Audio File] -->|File Import .m4a / .opus| REC
        REC -->|Audio File + SHA-256 Reference| DISK[(Local Storage)]
    end

    subgraph AIPipeline [Analysis Pipeline]
        DISK -->|Domain Prompt| STT[Configured Transcription Endpoint]
        STT -->|Raw Transcript| SCRUB[Optional Pattern-Based Redaction]
        SCRUB -->|Chunked When Long| LLM[Configured LLM Endpoint]
        LLM -->|Segmentation| DIAR[Speaker-Labeled Turns]
        LLM -->|Hypotheses, Tasks| STRUCT[Structured Results]
        LLM -->|Keywords, Queries| TERMS[Terms and Literature Queries]
    end

    subgraph KnowledgeLayer [Reference Layer]
        TERMS --> ATLAS[Local Term Atlas]
        TERMS -.->|When Online| PUBCHEM[PubChem PUG REST]
        TERMS -.->|When Online| PUBMED[PubMed E-Utilities]
    end

    subgraph NativeUI [Flutter Presentation]
        STRUCT --> DECK[Recording Deck and Quick Tags]
        DIAR --> SPEAKERS[Speakers Tab]
        ATLAS & PUBCHEM --> GLOSS[Glossary Tab]
        PUBMED --> READER[Article Reader]
        DISK --> LIGHTBOX[Figure Viewer]
        LLM <-->|Transcript Context| CHAT[Q and A Tab]
    end
```

---

## Getting real results with zero setup

No API keys, no terminal, no URLs, no accounts. Install and use:

1. **Record** — press the red button. Meetings save as 16 kHz WAV, the
   exact format the on-device engine reads.
2. **Transcribe** — press **Process AI insights**. The Whisper speech
   model downloads once on first use (Tiny 75 MB / Base 150 MB /
   Small 460 MB, chosen under Engine), then works fully offline.
   Long recordings transcribe in sequential parts with progress shown.
3. **Understand** — summaries, bench tasks, compounds, papers, and Q&A
   follow automatically. Synthesis uses a keyless hosted open model;
   everything else stays on your device.

Notes:
- Imported MP3/M4A files transcribe directly on Android. On
  Windows/Linux they need FFmpeg installed (`sudo apt install ffmpeg`),
  or import a WAV file instead.
- If no speech is found (silent audio), analysis stops with a clear
  message instead of invented text. See `docs/PIPELINE.md`.

## Engine settings (optional)

**Engine** in the app switches the Whisper model size and explains the
pipeline. There is nothing else to configure.

---

## Build Instructions

### 1. Android Package (`.apk`)

```bash
flutter build apk --release --split-per-abi

# build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
# build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk
# build/app/outputs/flutter-apk/app-x86_64-release.apk
```

### 2. Linux Debian Package (`.deb`)

```bash
./packaging/linux/build_deb.sh

# Install:
sudo dpkg -i labscribe_1.0.0_amd64.deb
labscribe
```

### 3. Windows Native Executable (`.exe`)

```powershell
flutter build windows --release
# Output folder: build\windows\x64\runner\Release\
```

---

## Public APIs Integration Details

Conforming to the [public-apis/public-apis](https://github.com/public-apis/public-apis) index:

1. **NCBI PubMed E-Utilities API** (`Category: Science & Math`):
   - Endpoints: `https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi` and `esummary.fcgi`
   - Used for literature search and summaries. Requests are rate-limited in-app (350ms delay between calls).
2. **NIH PubChem PUG REST API** (`Category: Science & Math`):
   - Endpoint: `https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/name/{name}/description/JSON`
   - Used for compound descriptions and CIDs.
3. **Free Dictionary API** (`Category: Dictionaries`):
   - Endpoint: `https://api.dictionaryapi.dev/api/v2/entries/en/{word}`
   - Used for general academic terms when the local atlas has no entry.
4. **LibreTranslate API** (`Category: Translation`):
   - Endpoint: configurable; defaults to `https://libretranslate.com/translate`
   - Used for transcript/summary translation. Requires a reachable instance.

---

## Limitations

- Transcription quality depends on audio quality, overlapping speech, accents, and the configured model.
- Speaker labels are inferred from dialogue flow, not voice biometrics.
- Redaction uses regular expressions and can miss or over-mask text. Always review before sharing.
- PubMed/PubChem results depend on network availability and upstream API changes.
- SHA-256 values are integrity references, not proof of regulatory compliance.

---

## License

Distributed under the Apache 2.0 License. See `LICENSE` for details.
