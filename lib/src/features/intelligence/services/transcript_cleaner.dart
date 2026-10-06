/// Post-processing cleanup for on-device Whisper output.
///
/// Raw speech-to-text commonly contains non-speech annotations
/// (`[BLANK_AUDIO]`, `[music]`, `[silence]`), hallucinated sentence loops
/// on quiet audio, filler words ("um", "uh", "hmm") and ragged whitespace.
/// This pass removes them so the saved transcript — and everything
/// synthesized from it — reads cleanly, like meeting notes rather than a
/// raw dictation.
/// Pure string logic: no plugins, no network.
class TranscriptCleaner {
  static final RegExp _bracketed = RegExp(r'\[[^\[\]]{0,80}\]');
  static final RegExp _sentenceSplit = RegExp(r'(?<=[.!?])\s+|\n+');
  static final RegExp _wsRun = RegExp(r'\s{2,}');

  /// Standalone filled pauses and thinking noises.
  ///
  /// Ordered longest-first so multi-character variants (`mm-hmm`, `mhm`)
  /// win over the shorter roots. Boundaries are enforced by the surrounding
  /// pattern, so substrings of real words (`her` → `er`, `human` → `um`)
  /// never match.
  static final String _fillerAlternatives = [
    'mm-hmm',
    'mmhm',
    'mhm',
    'hmm+',
    'hm+',
    'um+',
    'uhm+',
    'uh+',
    'erm+',
    'er+',
    'ahem',
    'ah+',
    'eh+',
    'mm+',
    'huh',
  ].join('|');

  /// A filler plus the separator that introduced it, so the filler can be
  /// dropped while everything around it stays intact:
  ///
  /// - `So, um, today`  → `So, today`   (leading space kept, comma consumed)
  /// - `um we tested`   → `we tested`   (sentence start)
  /// - `yes um.`        → `yes.`        (trailing period preserved)
  ///
  /// Sentence-ending punctuation is never consumed — that would glue two
  /// sentences together. Group 1 is the lead (empty at sentence start, which
  /// also tells the caller to restore capitalization afterwards).
  static final RegExp _fillerWords = RegExp(
    r"""(^|[\s(,;:'“”‘’"])"""
    '(?:$_fillerAlternatives)'
    r'(?:[,;:]+)?'
    r"""(?=[\s)”’'.,!?;:]|$)""",
    caseSensitive: false,
  );

  /// Punctuation cleanup after a filler has been removed.
  static final RegExp _spaceBeforePunct = RegExp(r'\s+([.!?;:,])');
  static final RegExp _separatorBeforeStop = RegExp(r'([,;:])\s*([.!?])');
  static final RegExp _danglingLead = RegExp(r'^\s*[,;:]\s*');
  static final RegExp _doubledSeparator = RegExp(r'([,;:])\s*(?=[,;:])');
  static final RegExp _cappedRun = RegExp(r'[.!?]{3,}');
  static final RegExp _alphaStart = RegExp(r'[a-z]');

  /// Cleans one transcript (whole file or single chunk).
  static String clean(String text) {
    if (text.trim().isEmpty) return '';
    var t = text.replaceAll(_bracketed, ' ');
    // Collapse adjacent duplicate sentences (hallucinated loops), keeping
    // the first occurrence. Comparison is case-insensitive on normalized
    // whitespace so "Hello. hello." still collapses.
    final out = <String>[];
    for (final raw in t.split(_sentenceSplit)) {
      var removedAtStart = false;
      var s = raw.replaceAllMapped(_fillerWords, (m) {
        if (m.group(1)!.isEmpty) removedAtStart = true;
        return m.group(1)!;
      });
      s = _tidyPunctuation(s);
      s = s.replaceAll(_wsRun, ' ').trim();
      if (s.isEmpty) continue;
      // A sentence that was only filler + punctuation collapses to bare
      // punctuation — drop it instead of leaving a stray "." behind.
      if (!s.contains(RegExp(r'\w'))) continue;
      // Removing a leading filler left the sentence lowercase; put the
      // capital back ("um we observed" → "We observed"). Only applied when
      // the filler was at the very start, so acronyms like "qPCR" survive.
      if (removedAtStart &&
          s.isNotEmpty &&
          _alphaStart.hasMatch(s) &&
          s[0] == s[0].toLowerCase()) {
        s = s[0].toUpperCase() + s.substring(1);
      }
      if (out.isNotEmpty && out.last.toLowerCase() == s.toLowerCase()) {
        continue;
      }
      out.add(s);
    }
    t = out.join(' ');
    // Cap runaway punctuation (e.g. "?!?!?!" or "!!!") at two marks.
    t = t.replaceAllMapped(
      _cappedRun,
      (m) => m[0]!.substring(0, 2),
    );
    return _tidyPunctuation(t).replaceAll(_wsRun, ' ').trim();
  }

  /// Fixes the punctuation scars a removed filler leaves behind.
  static String _tidyPunctuation(String s) {
    // "yes , um today" → "yes, today"
    s = s.replaceAllMapped(_spaceBeforePunct, (m) => m.group(1)!);
    // "yes, ." → "yes."   (filler between a comma and the period went away)
    s = s.replaceAllMapped(_separatorBeforeStop, (m) => m.group(2)!);
    // ", something" at the start of a sentence → "something"
    s = s.replaceAll(_danglingLead, '');
    // ", ," → ","   (drop the earlier of two adjacent separators)
    s = s.replaceAll(_doubledSeparator, '');
    return s;
  }
}
