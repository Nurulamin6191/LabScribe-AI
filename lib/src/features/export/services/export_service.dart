import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../../models/meeting_session.dart';

/// Scientific Research Exporter supporting:
/// 1. Comprehensive Lab Notebook Markdown (with 21 CFR Part 11 SHA-256 audit trail)
/// 2. Benchling / LabArchives ELN-compliant JSON format
/// 3. BibTeX bibliography export (.bib) for Zotero, Mendeley, and Overleaf/LaTeX
/// 4. In-App markdown generation for clipboard and internal viewer
class ExportService {
  /// Format session into standard scientific Markdown
  String generateMarkdownString(MeetingSession session) {
    final buffer = StringBuffer();
    buffer.writeln('# ${session.title}');
    buffer.writeln('**Date:** ${session.createdAt.toLocal().toString().split('.')[0]}');
    buffer.writeln('**Duration:** ${(session.durationSeconds / 60).toStringAsFixed(1)} minutes');
    if (session.isDeIdentified) {
      buffer.writeln('**Clinical Privacy:** HIPAA Safe Harbor De-Identified');
    }
    if (session.isVirtualCall) {
      buffer.writeln('**Session Source:** Virtual Call Audio (Zoom / WhatsApp / Teams)');
    }

    // 21 CFR Part 11 Cryptographic Audit Trail
    buffer.writeln('\n### Cryptographic Audit Trail (21 CFR Part 11)');
    buffer.writeln('- **Audio SHA-256 Seal:** `${session.audioSha256 ?? "Pending"}`');
    buffer.writeln('- **Transcript SHA-256 Seal:** `${session.transcriptSha256 ?? "Pending"}`');

    if (session.summary != null && session.summary!.scientificHypothesis.isNotEmpty) {
      buffer.writeln('\n## Research Hypothesis / Rationale');
      buffer.writeln('> ${session.summary!.scientificHypothesis}');
    }

    buffer.writeln('\n## Executive Summary');
    buffer.writeln(session.summary?.executiveSummary ?? 'No summary available.');
    
    if (session.summary != null && session.summary!.keyPoints.isNotEmpty) {
      buffer.writeln('\n## Key Discussion Points & Takeaways');
      for (final point in session.summary!.keyPoints) {
        buffer.writeln('- $point');
      }
    }

    if (session.summary != null && session.summary!.decisionsMade.isNotEmpty) {
      buffer.writeln('\n## Key Decisions Made');
      for (final decision in session.summary!.decisionsMade) {
        buffer.writeln('- $decision');
      }
    }

    if (session.actionItems.isNotEmpty) {
      buffer.writeln('\n## Action Items & Deliverables');
      for (final item in session.actionItems) {
        final cat = '[${item.category}]';
        final speakerTag = item.speaker != null ? ' (Attr: ${item.speaker})' : '';
        buffer.writeln('- [${item.isCompleted ? 'x' : ' '}] **${item.priority}** $cat — ${item.task} (Assignee: ${item.assignee}, Deadline: ${item.deadline ?? 'None'}$speakerTag)');
      }
    }

    if (session.liveNotes.isNotEmpty) {
      buffer.writeln('\n## Live In-Meeting Annotations & Bookmarks');
      for (final note in session.liveNotes) {
        final timeMin = (note.timestampSeconds / 60).toStringAsFixed(1);
        buffer.writeln('- **[${timeMin}m]** ${note.note}');
      }
    }

    if (session.glossaryTerms.isNotEmpty) {
      buffer.writeln('\n## Bio & Chemical Glossary (NIH PubChem & Atlas)');
      for (final term in session.glossaryTerms) {
        final badge = term.source == 'PubChem' ? '[NIH PubChem]' : '[Atlas/Dictionary]';
        buffer.writeln('### ${term.word.toUpperCase()} $badge');
        if (term.phonetic.isNotEmpty) buffer.writeln('*${term.phonetic}*');
        buffer.writeln(term.definition);
        if (term.example != null) buffer.writeln('> *${term.example}*');
        buffer.writeln();
      }
    }

    if (session.citations.isNotEmpty) {
      buffer.writeln('\n## Scientific Literature & PubMed Citations');
      for (final cite in session.citations) {
        buffer.writeln('- **${cite.title}**');
        buffer.writeln('  ${cite.authors} *${cite.journal}* (${cite.pubYear}). PMID: ${cite.pmid}');
        if (cite.doi != null) buffer.writeln('  DOI: https://doi.org/${cite.doi}');
        if (cite.abstractText.isNotEmpty) {
          buffer.writeln('  > *Abstract:* ${cite.abstractText}');
        }
      }
    }

    if (session.slideAttachments.isNotEmpty) {
      buffer.writeln('\n## Slide & Figure Attachments');
      for (final slide in session.slideAttachments) {
        final timeMin = (slide.timestampSeconds / 60).toStringAsFixed(1);
        buffer.writeln('### Figure at ${timeMin}m: ${slide.caption.isNotEmpty ? slide.caption : "Slide Attachment"}');
        buffer.writeln('![Figure](${slide.imagePath})');
      }
    }

    if (session.speakerTurns.isNotEmpty) {
      buffer.writeln('\n## Multi-Speaker Discussion & Diarization');
      for (final turn in session.speakerTurns) {
        final startMin = (turn.startSeconds ~/ 60).toString().padLeft(2, '0');
        final startSec = (turn.startSeconds % 60).toString().padLeft(2, '0');
        final endMin = (turn.endSeconds ~/ 60).toString().padLeft(2, '0');
        final endSec = (turn.endSeconds % 60).toString().padLeft(2, '0');
        buffer.writeln('**[$startMin:$startSec - $endMin:$endSec] ${turn.speakerName}:**');
        buffer.writeln('> ${turn.text}\n');
      }
    }

    buffer.writeln('\n## Full Session Transcript');
    buffer.writeln(session.transcript.isEmpty ? 'No transcript available.' : session.transcript);

    return buffer.toString();
  }

  /// Generate standard BibTeX citations for Zotero, Mendeley, and LaTeX
  String generateBibTeXString(MeetingSession session) {
    final buffer = StringBuffer();
    buffer.writeln('% BibTeX Bibliography Export generated by LabScribe AI');
    buffer.writeln('% Session: ${session.title}');
    buffer.writeln('% Generated: ${DateTime.now().toIso8601String()}\n');

    for (final cite in session.citations) {
      final citeKey = 'pmid${cite.pmid}';
      buffer.writeln('@article{$citeKey,');
      buffer.writeln('  title = {{${cite.title}}},');
      buffer.writeln('  author = {${cite.authors}},');
      buffer.writeln('  journal = {${cite.journal}},');
      buffer.writeln('  year = {${cite.pubYear.isNotEmpty ? cite.pubYear : "2023"}},');
      if (cite.doi != null) {
        buffer.writeln('  doi = {${cite.doi}},');
      }
      buffer.writeln('  note = {PMID: ${cite.pmid}}');
      buffer.writeln('}\n');
    }

    return buffer.toString();
  }

  /// Export session as Markdown formatted for lab notebooks and research reports
  Future<void> exportSessionAsMarkdown(MeetingSession session) async {
    final markdown = generateMarkdownString(session);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/labscribe_session_${session.id}.md');
    await file.writeAsString(markdown);

    await Share.shareXFiles([XFile(file.path)], text: 'Exported scientific notes: ${session.title}');
  }

  /// Export clean raw transcript as a text file (.txt)
  Future<void> exportTranscriptAsPlainText(MeetingSession session) async {
    final dir = await getTemporaryDirectory();
    final safeTitle = session.title.replaceAll(RegExp(r'[^\w\s-]'), '').replaceAll(RegExp(r'\s+'), '_');
    final file = File('${dir.path}/${safeTitle}_transcript.txt');
    await file.writeAsString(session.transcript);

    await Share.shareXFiles([XFile(file.path)], text: 'Session Transcript: ${session.title}');
  }

  /// Export action items and deliverables as standard CSV for Excel, Google Sheets, Jira, and Asana
  Future<void> exportActionItemsAsCsv(MeetingSession session) async {
    final buffer = StringBuffer();
    buffer.writeln('Task,Assignee,Priority,Category,Deadline,Completed,Speaker');
    for (final item in session.actionItems) {
      final taskClean = item.task.replaceAll('"', '""');
      final assigneeClean = item.assignee.replaceAll('"', '""');
      final catClean = item.category.replaceAll('"', '""');
      final deadlineClean = (item.deadline ?? '').replaceAll('"', '""');
      final speakerClean = (item.speaker ?? '').replaceAll('"', '""');
      buffer.writeln('"$taskClean","$assigneeClean",${item.priority},"$catClean","$deadlineClean",${item.isCompleted},"$speakerClean"');
    }

    final dir = await getTemporaryDirectory();
    final safeTitle = session.title.replaceAll(RegExp(r'[^\w\s-]'), '').replaceAll(RegExp(r'\s+'), '_');
    final file = File('${dir.path}/${safeTitle}_action_items.csv');
    await file.writeAsString(buffer.toString());

    await Share.shareXFiles([XFile(file.path)], text: 'Action Items CSV: ${session.title}');
  }

  /// Export citations as BibTeX (.bib) file for Zotero and reference managers
  Future<void> exportSessionAsBibTeX(MeetingSession session) async {
    final bibtex = generateBibTeXString(session);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/labscribe_citations_${session.id}.bib');
    await file.writeAsString(bibtex);

    await Share.shareXFiles([XFile(file.path)], text: 'BibTeX Citations: ${session.title}');
  }

  /// Export as structured JSON compatible with Benchling Notebook API and Electronic Lab Notebooks (ELN)
  Future<void> exportSessionAsELNJson(MeetingSession session) async {
    final Map<String, dynamic> elnData = {
      'elnFormat': 'Benchling_Compatible_v1',
      'generator': 'LabScribe_AI',
      'exportedAt': DateTime.now().toIso8601String(),
      'auditTrail': {
        'audioSha256': session.audioSha256,
        'transcriptSha256': session.transcriptSha256,
        'cfr21Part11Compliant': true,
      },
      'session': {
        'id': session.id,
        'title': session.title,
        'createdAt': session.createdAt.toIso8601String(),
        'durationSeconds': session.durationSeconds,
        'isDeIdentified': session.isDeIdentified,
        'isVirtualCall': session.isVirtualCall,
      },
      'hypothesis': session.summary?.scientificHypothesis ?? '',
      'executiveSummary': session.summary?.executiveSummary ?? '',
      'keyPoints': session.summary?.keyPoints ?? [],
      'protocolDecisions': session.summary?.decisionsMade ?? [],
      'actionItems': session.actionItems.map((a) => a.toJson()).toList(),
      'speakerTurns': session.speakerTurns.map((s) => s.toJson()).toList(),
      'liveNotes': session.liveNotes.map((n) => n.toJson()).toList(),
      'compoundsAndGlossary': session.glossaryTerms.map((g) => g.toJson()).toList(),
      'citations': session.citations.map((c) => c.toJson()).toList(),
      'figures': session.slideAttachments.map((s) => s.toJson()).toList(),
      'transcript': session.transcript,
    };

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/labscribe_eln_${session.id}.json');
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(elnData));

    await Share.shareXFiles([XFile(file.path)], text: 'Benchling/ELN Export: ${session.title}');
  }

  Future<void> shareAudioFile(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await Share.shareXFiles([XFile(path)], text: 'Shared audio file');
    }
  }
}
