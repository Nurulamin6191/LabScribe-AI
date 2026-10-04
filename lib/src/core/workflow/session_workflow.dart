import 'package:flutter/material.dart';

/// Session lifecycle for LabScribe AI.
///
/// Every session moves through one continuous flow instead of living as
/// disconnected tabs:
///
///   Capture → Transcribe → Synthesize → Review → Export
///
/// Pure logic (no widgets except icon/color mapping) so the rules can be
/// reasoned about and tested independently of the UI.
enum SessionStage {
  capture,
  transcribe,
  synthesize,
  review,
  export,
  done,
}

class SessionWorkflow {
  /// Ordered stages shown in the stepper (`done` means every step complete).
  static const List<SessionStage> visible = [
    SessionStage.capture,
    SessionStage.transcribe,
    SessionStage.synthesize,
    SessionStage.review,
    SessionStage.export,
  ];

  static SessionStage stageOf({
    required bool hasAudio,
    required bool isRecording,
    required bool hasTranscript,
    required bool hasSummary,
    required bool exported,
  }) {
    if (!hasAudio || isRecording) return SessionStage.capture;
    if (!hasTranscript) return SessionStage.transcribe;
    if (!hasSummary) return SessionStage.synthesize;
    if (!exported) return SessionStage.review;
    return SessionStage.done;
  }

  static String label(SessionStage stage) {
    switch (stage) {
      case SessionStage.capture:
        return 'Capture';
      case SessionStage.transcribe:
        return 'Transcribe';
      case SessionStage.synthesize:
        return 'Synthesize';
      case SessionStage.review:
        return 'Review';
      case SessionStage.export:
        return 'Export';
      case SessionStage.done:
        return 'Complete';
    }
  }

  static IconData icon(SessionStage stage) {
    switch (stage) {
      case SessionStage.capture:
        return Icons.mic_outlined;
      case SessionStage.transcribe:
        return Icons.graphic_eq_outlined;
      case SessionStage.synthesize:
        return Icons.auto_awesome_outlined;
      case SessionStage.review:
        return Icons.fact_check_outlined;
      case SessionStage.export:
        return Icons.ios_share_outlined;
      case SessionStage.done:
        return Icons.check_circle_outline;
    }
  }

  /// Stage accent used ONLY inside the stepper dots, so status color
  /// always means the same thing across the app.
  static Color color(SessionStage stage) {
    switch (stage) {
      case SessionStage.capture:
        return const Color(0xFFD92D20);
      case SessionStage.transcribe:
        return const Color(0xFFB77900);
      case SessionStage.synthesize:
        return const Color(0xFF3B5BFF);
      case SessionStage.review:
        return const Color(0xFF0A7C6B);
      case SessionStage.export:
        return const Color(0xFF15803D);
      case SessionStage.done:
        return const Color(0xFF15803D);
    }
  }

  static String hint(SessionStage stage) {
    switch (stage) {
      case SessionStage.capture:
        return 'Record or import audio to begin.';
      case SessionStage.transcribe:
        return 'Audio ready — transcribe it into text.';
      case SessionStage.synthesize:
        return 'Transcript ready — generate the synthesis.';
      case SessionStage.review:
        return 'Synthesis ready — review tasks and findings.';
      case SessionStage.export:
        return 'Reviewed — export the notebook.';
      case SessionStage.done:
        return 'Exported. Start a new session anytime.';
    }
  }
}
