/// Post-processing cleanup for on-device Whisper output.
///
/// Raw speech-to-text commonly contains non-speech annotations
/// (`[BLANK_AUDIO]`, `[music]`, `[silence]`), hallucinated sentence loops
/// on quiet audio, and ragged whitespace. This pass removes them so the
/// saved transcript — and everything synthesized from it — reads cleanly.
/// Pure string logic: no plugins, no network.
class TranscriptCleaner {
  static final RegExp _bracketed = RegExp(r'\[[^\[\]]{0,80}\]');
  static final RegExp _sentenceSplit = RegExp(r'(?<=[.!?])\s+|\n+');
  static final RegExp _wsRun = RegExp(r'\s{2,}');

  /// Cleans one transcript (whole file or single chunk).
  static String clean(String text) {
    if (text.trim().isEmpty) return '';
    var t = text.replaceAll(_bracketed, ' ');
    // Collapse adjacent duplicate sentences (hallucinated loops), keeping
    // the first occurrence. Comparison is case-insensitive on normalized
    // whitespace so "Hello. hello." still collapses.
    final out = <String>[];
    for (final raw in t.split(_sentenceSplit)) {
      final s = raw.replaceAll(_wsRun, ' ').trim();
      if (s.isEmpty) continue;
      if (out.isNotEmpty && out.last.toLowerCase() == s.toLowerCase()) {
        continue;
      }
      out.add(s);
    }
    t = out.join(' ');
    // Cap runaway punctuation (e.g. "?!?!?!") at two marks.
    t = t.replaceAllMapped(
      RegExp(r'([.!?])\1{2,}'),
      (m) => '${m[1]}${m[1]}',
    );
    return t.replaceAll(_wsRun, ' ').trim();
  }
}
