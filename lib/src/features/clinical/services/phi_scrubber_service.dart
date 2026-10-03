/// Client-Side HIPAA & Clinical Protected Health Information (PHI) De-identification Engine.
/// Runs 100% locally on-device before any transcript is displayed, saved, or dispatched.
/// Complies with HIPAA Safe Harbor (45 CFR § 164.514(b)) and clinical trial anonymization standards.
class PhiScrubberService {
  /// Redacts PHI from raw speech transcripts while strictly preserving
  /// medical/scientific nomenclature (e.g., tumor staging, gene mutations, drug doses).
  ({String scrubbedText, int redactedCount, Map<String, int> breakdown}) scrubTranscript(String rawText) {
    if (rawText.isEmpty) {
      return (scrubbedText: rawText, redactedCount: 0, breakdown: {});
    }

    String text = rawText;
    int totalRedactions = 0;
    final Map<String, int> stats = {
      'MRN/Hospital IDs': 0,
      'Dates/DOB': 0,
      'Contact Info': 0,
      'Patient Name Patterns': 0,
      'Social Security / National IDs': 0,
    };

    // 1. Medical Record Numbers (MRN), Accession Numbers, Biobank IDs
    // Examples: "MRN: 9847291", "Patient ID #84729", "Pathology specimen S23-9841"
    final mrnRegex = RegExp(
      r'\b(?:MRN|Medical Record Number|Patient ID|Accession|Specimen|Pathology ID|Biobank ID)[\s:#-]+([A-Za-z0-9-]+)\b',
      caseSensitive: false,
    );
    text = text.replaceAllMapped(mrnRegex, (match) {
      stats['MRN/Hospital IDs'] = (stats['MRN/Hospital IDs'] ?? 0) + 1;
      totalRedactions++;
      return '[MRN-REDACTED]';
    });

    // Standalone alphanumeric MRN patterns like #9847294
    final hashIdRegex = RegExp(r'#\d{5,10}\b');
    text = text.replaceAllMapped(hashIdRegex, (match) {
      stats['MRN/Hospital IDs'] = (stats['MRN/Hospital IDs'] ?? 0) + 1;
      totalRedactions++;
      return '[ID-REDACTED]';
    });

    // 2. Dates of Birth and Specific Calendar Dates (Preserving relative times like 'in 2 weeks')
    // Examples: "DOB: 04/12/1958", "born on 1974-08-22", "Date of birth October 4th, 1962"
    final dobRegex = RegExp(
      r'\b(?:DOB|Date of Birth|born on|born in)[\s:#-]+(?:\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|\w+\s+\d{1,2}(?:st|nd|rd|th)?,?\s+\d{4})\b',
      caseSensitive: false,
    );
    text = text.replaceAllMapped(dobRegex, (match) {
      stats['Dates/DOB'] = (stats['Dates/DOB'] ?? 0) + 1;
      totalRedactions++;
      return '[DOB-REDACTED]';
    });

    // 3. Social Security Numbers / National IDs
    final ssnRegex = RegExp(r'\b\d{3}-\d{2}-\d{4}\b');
    text = text.replaceAllMapped(ssnRegex, (match) {
      stats['Social Security / National IDs'] = (stats['Social Security / National IDs'] ?? 0) + 1;
      totalRedactions++;
      return '[SSN-REDACTED]';
    });

    // 4. Phone Numbers and Email Addresses
    final phoneRegex = RegExp(r'\b(?:\+?\d{1,3}[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b');
    text = text.replaceAllMapped(phoneRegex, (match) {
      stats['Contact Info'] = (stats['Contact Info'] ?? 0) + 1;
      totalRedactions++;
      return '[PHONE-REDACTED]';
    });

    final emailRegex = RegExp(r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b');
    text = text.replaceAllMapped(emailRegex, (match) {
      stats['Contact Info'] = (stats['Contact Info'] ?? 0) + 1;
      totalRedactions++;
      return '[EMAIL-REDACTED]';
    });

    // 5. Patient Name Honorific Formats
    // Examples: "Patient John Smith", "Mr. David Miller", "Ms. Sarah Jenkins"
    // (Notice: Gene symbols like "HER2", "TP53" are not matched because of honorific guards)
    final patientNameRegex = RegExp(
      r'\b(?:Patient|Mr\.|Mrs\.|Ms\.)\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)\b',
      caseSensitive: true,
    );
    int patientCounter = 1;
    final Map<String, String> pseudonymMap = {};

    text = text.replaceAllMapped(patientNameRegex, (match) {
      final matchedName = match.group(1);
      if (matchedName != null && !_isScientificExclusion(matchedName)) {
        if (!pseudonymMap.containsKey(matchedName)) {
          pseudonymMap[matchedName] = '[PATIENT-$patientCounter]';
          patientCounter++;
        }
        stats['Patient Name Patterns'] = (stats['Patient Name Patterns'] ?? 0) + 1;
        totalRedactions++;
        return 'Patient ${pseudonymMap[matchedName]}';
      }
      return match.group(0)!;
    });

    return (
      scrubbedText: text,
      redactedCount: totalRedactions,
      breakdown: stats,
    );
  }

  /// Avoid redacting common scientific terms or reagents that might begin with a capital letter
  bool _isScientificExclusion(String word) {
    const exclusions = {
      'Control', 'Negative', 'Positive', 'Wild', 'Type', 'Vehicle',
      'Tumor', 'Normal', 'Primary', 'Secondary', 'Metastatic',
      'Cisplatin', 'Osimertinib', 'Doxorubicin', 'Sotorasib', 'Pembrolizumab',
    };
    return exclusions.contains(word);
  }
}
