import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/meeting_session.dart';

class SessionRepository {
  static final SessionRepository _instance = SessionRepository._internal();
  factory SessionRepository() => _instance;
  SessionRepository._internal();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDB();
    return _db!;
  }

  Future<Database> _initDB() async {
    String path = join(await getDatabasesPath(), 'labscribe_sessions.db');
    final db = await openDatabase(
      path,
      version: 5,
      onCreate: (db, version) async {
        await _createTable(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          try {
            await db.execute('ALTER TABLE sessions ADD COLUMN citationsJson TEXT');
            await db.execute('ALTER TABLE sessions ADD COLUMN slideAttachmentsJson TEXT');
            await db.execute('ALTER TABLE sessions ADD COLUMN glossaryTermsJson TEXT');
            await db.execute('ALTER TABLE sessions ADD COLUMN isDeIdentified INTEGER DEFAULT 0');
          } catch (_) {}
        }
        if (oldVersion < 3) {
          try {
            await db.execute('ALTER TABLE sessions ADD COLUMN liveNotesJson TEXT');
          } catch (_) {}
        }
        if (oldVersion < 4) {
          try {
            await db.execute('ALTER TABLE sessions ADD COLUMN audioSha256 TEXT');
            await db.execute('ALTER TABLE sessions ADD COLUMN transcriptSha256 TEXT');
          } catch (_) {}
        }
        if (oldVersion < 5) {
          try {
            await db.execute('ALTER TABLE sessions ADD COLUMN speakerTurnsJson TEXT');
            await db.execute('ALTER TABLE sessions ADD COLUMN isVirtualCall INTEGER DEFAULT 0');
          } catch (_) {}
        }
      },
    );

    // Performance optimizations: Write-Ahead Logging & non-blocking synchronous mode
    try {
      await db.execute('PRAGMA journal_mode = WAL;');
      await db.execute('PRAGMA synchronous = NORMAL;');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_sessions_createdAt ON sessions(createdAt DESC);');
    } catch (_) {}

    return db;
  }

  Future<void> _createTable(Database db) async {
    await db.execute('''
      CREATE TABLE sessions(
        id TEXT PRIMARY KEY,
        title TEXT,
        createdAt TEXT,
        audioPath TEXT,
        durationSeconds INTEGER,
        transcript TEXT,
        summaryJson TEXT,
        actionItemsJson TEXT,
        citationsJson TEXT,
        slideAttachmentsJson TEXT,
        glossaryTermsJson TEXT,
        liveNotesJson TEXT,
        isDeIdentified INTEGER DEFAULT 0,
        audioSha256 TEXT,
        transcriptSha256 TEXT,
        speakerTurnsJson TEXT,
        isVirtualCall INTEGER DEFAULT 0
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_sessions_createdAt ON sessions(createdAt DESC);');
  }

  Future<void> saveSession(MeetingSession session) async {
    final db = await database;
    
    String? summaryJson = session.summary != null ? jsonEncode(session.summary!.toJson()) : null;
    String actionItemsJson = jsonEncode(session.actionItems.map((e) => e.toJson()).toList());
    String citationsJson = jsonEncode(session.citations.map((e) => e.toJson()).toList());
    String slideAttachmentsJson = jsonEncode(session.slideAttachments.map((e) => e.toJson()).toList());
    String glossaryTermsJson = jsonEncode(session.glossaryTerms.map((e) => e.toJson()).toList());
    String liveNotesJson = jsonEncode(session.liveNotes.map((e) => e.toJson()).toList());
    String speakerTurnsJson = jsonEncode(session.speakerTurns.map((e) => e.toJson()).toList());

    await db.insert(
      'sessions',
      {
        'id': session.id,
        'title': session.title,
        'createdAt': session.createdAt.toIso8601String(),
        'audioPath': session.audioPath,
        'durationSeconds': session.durationSeconds,
        'transcript': session.transcript,
        'summaryJson': summaryJson,
        'actionItemsJson': actionItemsJson,
        'citationsJson': citationsJson,
        'slideAttachmentsJson': slideAttachmentsJson,
        'glossaryTermsJson': glossaryTermsJson,
        'liveNotesJson': liveNotesJson,
        'isDeIdentified': session.isDeIdentified ? 1 : 0,
        'audioSha256': session.audioSha256,
        'transcriptSha256': session.transcriptSha256,
        'speakerTurnsJson': speakerTurnsJson,
        'isVirtualCall': session.isVirtualCall ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<MeetingSession>> loadAllSessions() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('sessions', orderBy: 'createdAt DESC');

    return maps.map((map) => _mapToSession(map)).toList();
  }

  Future<MeetingSession?> loadSession(String id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('sessions', where: 'id = ?', whereArgs: [id]);
    
    if (maps.isNotEmpty) {
      return _mapToSession(maps.first);
    }
    return null;
  }

  Future<void> deleteSession(String id) async {
    final db = await database;
    await db.delete('sessions', where: 'id = ?', whereArgs: [id]);
  }

  MeetingSession _mapToSession(Map<String, dynamic> map) {
    SummaryResult? summary;
    if (map['summaryJson'] != null) {
      summary = SummaryResult.fromJson(jsonDecode(map['summaryJson']));
    }

    List<ActionItem> actionItems = [];
    if (map['actionItemsJson'] != null) {
      final List<dynamic> jsonList = jsonDecode(map['actionItemsJson']);
      actionItems = jsonList.map((e) => ActionItem.fromJson(e)).toList();
    }

    List<PubMedCitation> citations = [];
    if (map['citationsJson'] != null) {
      final List<dynamic> jsonList = jsonDecode(map['citationsJson']);
      citations = jsonList.map((e) => PubMedCitation.fromJson(e)).toList();
    }

    List<SlideAttachment> slideAttachments = [];
    if (map['slideAttachmentsJson'] != null) {
      final List<dynamic> jsonList = jsonDecode(map['slideAttachmentsJson']);
      slideAttachments = jsonList.map((e) => SlideAttachment.fromJson(e)).toList();
    }

    List<GlossaryTerm> glossaryTerms = [];
    if (map['glossaryTermsJson'] != null) {
      final List<dynamic> jsonList = jsonDecode(map['glossaryTermsJson']);
      glossaryTerms = jsonList.map((e) => GlossaryTerm.fromJson(e)).toList();
    }

    List<SpeakerTurn> speakerTurns = [];
    if (map['speakerTurnsJson'] != null) {
      final List<dynamic> jsonList = jsonDecode(map['speakerTurnsJson']);
      speakerTurns = jsonList.map((e) => SpeakerTurn.fromJson(e)).toList();
    }

    List<MeetingNote> liveNotes = [];
    if (map['liveNotesJson'] != null) {
      final List<dynamic> jsonList = jsonDecode(map['liveNotesJson']);
      liveNotes = jsonList.map((e) => MeetingNote.fromJson(e)).toList();
    }

    return MeetingSession(
      id: map['id'],
      title: map['title'],
      createdAt: DateTime.parse(map['createdAt']),
      audioPath: map['audioPath'],
      durationSeconds: map['durationSeconds'] ?? 0,
      transcript: map['transcript'] ?? '',
      summary: summary,
      actionItems: actionItems,
      citations: citations,
      slideAttachments: slideAttachments,
      liveNotes: liveNotes,
      glossaryTerms: glossaryTerms,
      speakerTurns: speakerTurns,
      isDeIdentified: (map['isDeIdentified'] ?? 0) == 1,
      isVirtualCall: (map['isVirtualCall'] ?? 0) == 1,
      audioSha256: map['audioSha256'],
      transcriptSha256: map['transcriptSha256'],
    );
  }
}
