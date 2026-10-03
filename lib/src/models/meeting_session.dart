import 'dart:convert';
import 'package:uuid/uuid.dart';

/// Status of the audio recording engine
enum RecordingState {
  idle,
  recording,
  paused,
  stopped,
}

/// Pipeline progress states for AI post-processing
enum ProcessingStage {
  idle,
  transcribing,
  deidentifying,
  summarizing,
  extractingTasks,
  buildingGlossary,
  resolvingCitations,
  completed,
  error,
}

/// Lab protocol or meeting task extracted from scientific transcripts
class ActionItem {
  final String id;
  final String task;
  String assignee;
  final String? deadline;
  final String priority; // High, Medium, Low
  final String category; // 'Bench Assay', 'Reagents', 'Data Analysis', 'Clinical/IRB', 'Manuscript'
  String? speaker; // Attributed speaker who agreed or assigned the task
  bool isCompleted;

  ActionItem({
    required this.id,
    required this.task,
    this.assignee = 'Unassigned',
    this.deadline,
    this.priority = 'Medium',
    this.category = 'Bench Assay',
    this.speaker,
    this.isCompleted = false,
  });

  factory ActionItem.fromJson(Map<String, dynamic> json) {
    return ActionItem(
      id: json['id'] ?? const Uuid().v4(),
      task: json['task'] ?? '',
      assignee: json['assignee'] ?? 'Unassigned',
      deadline: json['deadline'],
      priority: json['priority'] ?? 'Medium',
      category: json['category'] ?? 'Bench Assay',
      speaker: json['speaker'],
      isCompleted: json['isCompleted'] ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'task': task,
        'assignee': assignee,
        'deadline': deadline,
        'priority': priority,
        'category': category,
        'speaker': speaker,
        'isCompleted': isCompleted,
      };
}

/// Structured summary representation for scientific/biomedical discussions
class SummaryResult {
  final String executiveSummary;
  final List<String> keyPoints;
  final List<String> decisionsMade;
  final String scientificHypothesis;
  final String detectedLanguage;

  SummaryResult({
    required this.executiveSummary,
    required this.keyPoints,
    required this.decisionsMade,
    this.scientificHypothesis = '',
    this.detectedLanguage = 'English / Scientific Multilingual',
  });

  factory SummaryResult.fromJson(Map<String, dynamic> json) {
    return SummaryResult(
      executiveSummary: json['executiveSummary'] ?? '',
      keyPoints: List<String>.from(json['keyPoints'] ?? []),
      decisionsMade: List<String>.from(json['decisionsMade'] ?? []),
      scientificHypothesis: json['scientificHypothesis'] ?? '',
      detectedLanguage: json['detectedLanguage'] ?? 'English / Scientific Multilingual',
    );
  }

  Map<String, dynamic> toJson() => {
        'executiveSummary': executiveSummary,
        'keyPoints': keyPoints,
        'decisionsMade': decisionsMade,
        'scientificHypothesis': scientificHypothesis,
        'detectedLanguage': detectedLanguage,
      };
}

/// Scientific glossary entry sourced from NIH PubChem, Dictionary API, or built-in Atlas.
class GlossaryTerm {
  final String word;
  final String phonetic;
  final String partOfSpeech;
  final String definition;
  final String? example;
  final String source; // 'PubChem', 'Dictionary', 'BioKnowledge', 'LLM'

  GlossaryTerm({
    required this.word,
    this.phonetic = '',
    this.partOfSpeech = '',
    required this.definition,
    this.example,
    this.source = 'Dictionary',
  });

  factory GlossaryTerm.fromDictionaryApi(Map<String, dynamic> json) {
    final word = json['word'] ?? '';
    final phonetic = json['phonetic'] ?? '';
    final meanings = (json['meanings'] as List?) ?? [];
    String partOfSpeech = '';
    String definition = 'No definition available.';
    String? example;

    if (meanings.isNotEmpty) {
      final firstMeaning = meanings.first as Map<String, dynamic>;
      partOfSpeech = firstMeaning['partOfSpeech'] ?? '';
      final defs = (firstMeaning['definitions'] as List?) ?? [];
      if (defs.isNotEmpty) {
        final firstDef = defs.first as Map<String, dynamic>;
        definition = firstDef['definition'] ?? definition;
        example = firstDef['example'];
      }
    }

    return GlossaryTerm(
      word: word,
      phonetic: phonetic,
      partOfSpeech: partOfSpeech,
      definition: definition,
      example: example,
      source: 'Dictionary',
    );
  }

  Map<String, dynamic> toJson() => {
        'word': word,
        'phonetic': phonetic,
        'partOfSpeech': partOfSpeech,
        'definition': definition,
        'example': example,
        'source': source,
      };

  factory GlossaryTerm.fromJson(Map<String, dynamic> json) {
    return GlossaryTerm(
      word: json['word'] ?? '',
      phonetic: json['phonetic'] ?? '',
      partOfSpeech: json['partOfSpeech'] ?? '',
      definition: json['definition'] ?? '',
      example: json['example'],
      source: json['source'] ?? 'Dictionary',
    );
  }
}

/// PubMed citation reference resolved from NCBI E-Utilities or built-in Atlas.
/// Includes abstractText for in-app reading without external browsers.
class PubMedCitation {
  final String pmid;
  final String title;
  final String authors;
  final String journal;
  final String pubYear;
  final String? doi;
  final String url;
  final String abstractText;

  PubMedCitation({
    required this.pmid,
    required this.title,
    required this.authors,
    required this.journal,
    required this.pubYear,
    this.doi,
    String? url,
    this.abstractText = 'Abstract text available for in-app review.',
  }) : url = url ?? 'https://pubmed.ncbi.nlm.nih.gov/$pmid/';

  factory PubMedCitation.fromJson(Map<String, dynamic> json) {
    return PubMedCitation(
      pmid: json['pmid'] ?? '',
      title: json['title'] ?? '',
      authors: json['authors'] ?? '',
      journal: json['journal'] ?? '',
      pubYear: json['pubYear'] ?? '',
      doi: json['doi'],
      url: json['url'],
      abstractText: json['abstractText'] ?? 'Abstract text available for in-app review.',
    );
  }

  Map<String, dynamic> toJson() => {
        'pmid': pmid,
        'title': title,
        'authors': authors,
        'journal': journal,
        'pubYear': pubYear,
        'doi': doi,
        'url': url,
        'abstractText': abstractText,
      };
}

/// Live timestamped bookmark/note recorded during an active meeting
class MeetingNote {
  final String id;
  final int timestampSeconds;
  final String note;
  final DateTime createdAt;

  MeetingNote({
    required this.id,
    required this.timestampSeconds,
    required this.note,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  factory MeetingNote.fromJson(Map<String, dynamic> json) {
    return MeetingNote(
      id: json['id'] ?? const Uuid().v4(),
      timestampSeconds: json['timestampSeconds'] ?? 0,
      note: json['note'] ?? '',
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'])
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestampSeconds': timestampSeconds,
        'note': note,
        'createdAt': createdAt.toIso8601String(),
      };
}

/// Slide deck snapshot or gel/FACS plot attached to the meeting timeline
class SlideAttachment {
  final String id;
  final String imagePath;
  final int timestampSeconds;
  final String caption;
  final DateTime capturedAt;

  SlideAttachment({
    required this.id,
    required this.imagePath,
    required this.timestampSeconds,
    this.caption = '',
    DateTime? capturedAt,
  }) : capturedAt = capturedAt ?? DateTime.now();

  factory SlideAttachment.fromJson(Map<String, dynamic> json) {
    return SlideAttachment(
      id: json['id'] ?? const Uuid().v4(),
      imagePath: json['imagePath'] ?? '',
      timestampSeconds: json['timestampSeconds'] ?? 0,
      caption: json['caption'] ?? '',
      capturedAt: json['capturedAt'] != null
          ? DateTime.parse(json['capturedAt'])
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'imagePath': imagePath,
        'timestampSeconds': timestampSeconds,
        'caption': caption,
        'capturedAt': capturedAt.toIso8601String(),
      };
}

/// Q&A Chat interaction message
class ChatMessage {
  final String sender; // 'user' or 'ai'
  final String text;
  final DateTime timestamp;

  ChatMessage({
    required this.sender,
    required this.text,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'sender': sender,
        'text': text,
        'timestamp': timestamp.toIso8601String(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      sender: json['sender'] ?? 'user',
      text: json['text'] ?? '',
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'])
          : DateTime.now(),
    );
  }
}

/// Structured multi-speaker conversational turn (Speaker Diarization)
class SpeakerTurn {
  final String id;
  final String speakerId; // e.g. "Speaker 1", "Speaker 2", "SPEAKER_00"
  String speakerName;     // Editable by researcher: e.g. "Dr. Aris (PI)", "Elena (Postdoc)"
  final int startSeconds;
  final int endSeconds;
  final String text;

  SpeakerTurn({
    required this.id,
    required this.speakerId,
    String? speakerName,
    required this.startSeconds,
    required this.endSeconds,
    required this.text,
  }) : speakerName = speakerName ?? speakerId;

  factory SpeakerTurn.fromJson(Map<String, dynamic> json) {
    final speakerId = json['speakerId'] ?? 'Speaker 1';
    return SpeakerTurn(
      id: json['id'] ?? const Uuid().v4(),
      speakerId: speakerId,
      speakerName: json['speakerName'] ?? speakerId,
      startSeconds: json['startSeconds'] ?? 0,
      endSeconds: json['endSeconds'] ?? 0,
      text: json['text'] ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'speakerId': speakerId,
        'speakerName': speakerName,
        'startSeconds': startSeconds,
        'endSeconds': endSeconds,
        'text': text,
      };
}

/// Master Meeting / Lecture Session record
class MeetingSession {
  final String id;
  String title;
  final DateTime createdAt;
  String? audioPath;
  int durationSeconds;
  String transcript;
  SummaryResult? summary;
  List<ActionItem> actionItems;
  List<GlossaryTerm> glossaryTerms;
  List<PubMedCitation> citations;
  List<SlideAttachment> slideAttachments;
  List<MeetingNote> liveNotes;
  List<ChatMessage> chatHistory;
  List<SpeakerTurn> speakerTurns;
  bool isDeIdentified;
  bool isVirtualCall;
  String? audioSha256;
  String? transcriptSha256;

  MeetingSession({
    required this.id,
    required this.title,
    required this.createdAt,
    this.audioPath,
    this.durationSeconds = 0,
    this.transcript = '',
    this.summary,
    List<ActionItem>? actionItems,
    List<GlossaryTerm>? glossaryTerms,
    List<PubMedCitation>? citations,
    List<SlideAttachment>? slideAttachments,
    List<MeetingNote>? liveNotes,
    List<ChatMessage>? chatHistory,
    List<SpeakerTurn>? speakerTurns,
    this.isDeIdentified = false,
    this.isVirtualCall = false,
    this.audioSha256,
    this.transcriptSha256,
  })  : actionItems = actionItems ?? [],
        glossaryTerms = glossaryTerms ?? [],
        citations = citations ?? [],
        slideAttachments = slideAttachments ?? [],
        liveNotes = liveNotes ?? [],
        chatHistory = chatHistory ?? [],
        speakerTurns = speakerTurns ?? [];

  /// Rename a speaker across all turns and action item attributions
  void renameSpeaker(String speakerId, String newName) {
    for (final turn in speakerTurns) {
      if (turn.speakerId == speakerId || turn.speakerName == speakerId) {
        turn.speakerName = newName;
      }
    }
    for (final item in actionItems) {
      if (item.speaker == speakerId) {
        item.speaker = newName;
      }
      if (item.assignee == speakerId) {
        item.assignee = newName;
      }
    }
  }
}
