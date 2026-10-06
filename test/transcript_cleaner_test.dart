import 'package:flutter_test/flutter_test.dart';
import 'package:labscribe/src/features/intelligence/services/transcript_cleaner.dart';

void main() {
  group('TranscriptCleaner.filler removal', () {
    const cases = <String, String>{
      'So, um, today we tested the protocol.': 'So, today we tested the protocol.',
      'Um we observed umm significant toxicity.': 'We observed significant toxicity.',
      'yes um.': 'yes.',
      'The patient had hmm no response.': 'The patient had no response.',
      'Hmm, the control looked fine.': 'The control looked fine.',
      'Primary endpoint: um, overall survival.': 'Primary endpoint: overall survival.',
      'Mm-hmm. Agreed.': 'Agreed.',
      'he said ah that the dose was 100 nM.': 'he said that the dose was 100 nM.',
      'err, the gel broke.': 'The gel broke.',
      'qPCR, mhm, in triplicate.': 'qPCR, in triplicate.',
    };

    cases.forEach((input, expected) {
      test('"$input"', () {
        expect(TranscriptCleaner.clean(input), expected);
      });
    });

    test('does not touch words that merely contain filler roots', () {
      const input = 'human behavior and her estimate remain important.';
      expect(TranscriptCleaner.clean(input), input);
    });

    test('removes a lone filler completely', () {
      expect(TranscriptCleaner.clean('um'), '');
      expect(TranscriptCleaner.clean('hmm...'), '');
    });

    test('collapses adjacent duplicate sentences', () {
      expect(
        TranscriptCleaner.clean('Great. Great. Next.'),
        'Great. Next.',
      );
    });

    test('strips bracketed non-speech annotations', () {
      expect(
        TranscriptCleaner.clean('we saw  [BLANK_AUDIO]  nothing'),
        'we saw nothing',
      );
    });

    test('repairs punctuation left behind by a removed filler', () {
      expect(TranscriptCleaner.clean('a, , b'), 'a, b');
      expect(TranscriptCleaner.clean('endpoint , um. Done'), 'endpoint. Done');
    });

    test('caps runaway punctuation', () {
      expect(TranscriptCleaner.clean('Really?!?!?!'), 'Really?!');
    });

    test('empty input stays empty', () {
      expect(TranscriptCleaner.clean(''), '');
      expect(TranscriptCleaner.clean('   '), '');
    });
  });
}
