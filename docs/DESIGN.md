# LabScribe AI — Product Design Notes

How the interface is organized, which industry conventions it follows,
and where it intentionally differs for bench-science use.

## 1. Reference apps compared

| App | Library | Session view | Capture UX | Analytics | What LabScribe adopts |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Otter.ai** | Home list with search, folders | Tabs: Summary (outline, action items), Transcript (searchable, speaker-labeled, click-to-seek), AI chat | Record button, live transcript | — | Tabbed notebook; searchable speaker-labeled transcript; per-turn seek |
| **Fireflies.ai** | Searchable meeting library, topic filters | Notebook: Summary, Action items, Transcript; soundbites | Auto-join bots (not applicable here) | Talk-time analytics, topic trackers | Notebook structure; talk-time bar; library filters |
| **Fathom / tl;dv** | Meeting list | Highlights/moments timeline, chapters, clips, instant summary | One-click highlight during calls | — | Key-moments timeline from bookmarks and figures; one-tap tags |
| **Gong** | Deal/account views | Trackers, call analytics | — | Talk ratios, speaker stats | Per-speaker aggregates (turns, words, share) |
| **Plaud / Notta** | Folderposed recordings | Summary + transcript + labels | Hardware/app record button | — | Record as a first-class destination; export formats |

Common conventions across all five: left navigation, a search-first library,
a tabbed session notebook, timestamped playback seek, and task lists with
owners and completion states.

## 2. Information architecture

One continuous session lifecycle, always visible in the persistent header:

```
Record → (overview) → Transcribe → Synthesize → Review → Export
```

The header shows the session title (tap the pencil to rename), a
five-step `StageStepper` (`lib/src/core/workflow/session_workflow.dart`),
and a single Continue button that always offers the next valid action:
Start recording → Transcribe & analyze → Generate insights → Review tasks
→ Export notes → New session. Finishing recording prompts transcription;
finishing analysis lands on the Overview; every export advances the stage.

Full destination map (header sits above all of these):

```
Record (capture deck: mic, timer, tags, processing)
Overview (stats · talk time · key moments · synthesis)
Transcript (search · speaker filter · timestamped turns)
Actions (progress · All/Open/Done/High filters)
Speakers (talk-time bar · per-speaker aggregates · turn timeline)
Compounds (PubChem + local atlas search)
Papers (PubMed search + in-app reader)
Ask (transcript-grounded Q&A)
Archive (search · type filters · sort)
```

Desktop ≥1200px shows a full sidebar; 900–1200px collapses to an icon rail;
below 900px a 5-destination bottom bar groups related tabs
(Overview+Transcript, Actions+Speakers, Compounds+Papers).

## 3. Design tokens

- Radii: 20px cards, 14px inputs/buttons, 99px pills and meters.
- Stage accents are fixed per stage (capture red, transcribe amber,
  synthesize indigo, review teal, export green) and appear only in the
  stepper dots; the primary Continue action is always teal.
- Type: system sans, 800-weight titles at 17–20px, 13–14.5px body at 1.5–1.75 line height,
  tabular figures for all timestamps.
- Color: teal primary (bench-science association), indigo for references,
  amber for caution/bookmarks. Status is never conveyed by color alone —
  every pill pairs an icon with a label.
- Density: 8px base spacing, 16–20px screen padding, 860–880px reading width
  for transcript and synthesis.

## 4. Deliberate differences from generic notetakers

- Record is a destination, not a modal: wet-lab sessions run long and the
  deck stays usable beside slides or a call window (compact dock preserved).
- Compounds and papers are first-class tabs, not side panels: resolving a
  drug or a PMID mid-review is a core bench task, not an edge case.
- Hashes and redaction flags are labeled as references and helpers, never
  as compliance certifications. See README `Limitations`.
- Speaker labels are editable everywhere because diarization here is
  dialogue-flow heuristics, not voice biometrics.

## 5. Out of scope / known gaps vs. industry

- No calendar integration, auto-join bots, or CRM sync (by design: on-device first).
- No real-time streaming transcript during recording.
- No clip sharing or timestamped links yet; moments currently seek locally.
- No cross-session search or topic tracking yet; archive search is per-field only.
