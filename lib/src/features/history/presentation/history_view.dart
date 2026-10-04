import 'package:flutter/material.dart';
import '../../../core/session_repository.dart';
import '../../../models/meeting_session.dart';
import '../../../core/widgets/labscribe_ui.dart';

/// Historical session browser with real-time scientific search,
/// metadata badges (redaction flag, SHA-256 reference, citations),
/// and swipe-to-delete.
class HistoryView extends StatefulWidget {
  const HistoryView({super.key});

  @override
  State<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<HistoryView> {
  List<MeetingSession> _allSessions = [];
  bool _isLoading = true;
  final TextEditingController _searchController = TextEditingController();
  int _histFilter = 0; // 0 All, 1 With tasks, 2 With papers, 3 With speakers
  int _histSort = 0; // 0 Newest, 1 Oldest, 2 Title A-Z

  @override
  void initState() {
    super.initState();
    _loadSessions();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadSessions() async {
    final sessions = await SessionRepository().loadAllSessions();
    if (!mounted) return;
    setState(() {
      _allSessions = sessions;
      _isLoading = false;
    });
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  /// Search query + type filter + sort, computed on demand like Fireflies/Otter libraries.
  List<MeetingSession> _visibleSessions() {
    final query = _searchController.text.trim().toLowerCase();
    var list = _allSessions.where((s) {
      final matchesQuery = query.isEmpty ||
          s.title.toLowerCase().contains(query) ||
          (s.summary?.scientificHypothesis.toLowerCase().contains(query) ?? false) ||
          s.transcript.toLowerCase().contains(query) ||
          s.createdAt.toLocal().toString().toLowerCase().contains(query);
      if (!matchesQuery) return false;
      switch (_histFilter) {
        case 1:
          return s.actionItems.isNotEmpty;
        case 2:
          return s.citations.isNotEmpty;
        case 3:
          return s.speakerTurns.isNotEmpty;
        default:
          return true;
      }
    }).toList();
    switch (_histSort) {
      case 1:
        list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        break;
      case 2:
        list.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        break;
      default:
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    return list;
  }

  Future<void> _deleteSession(String id) async {
    await SessionRepository().deleteSession(id);
    _loadSessions();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            BrandMark(size: 30),
            SizedBox(width: 10),
            Text('Session archive'),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(112),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Column(
              children: [
                TextField(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Search title, hypothesis, gene, PMID or date…',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 17),
                            onPressed: () => _searchController.clear(),
                          )
                        : null,
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            ChoiceChip(label: const Text('All', style: TextStyle(fontSize: 12)), selected: _histFilter == 0, onSelected: (_) => setState(() => _histFilter = 0), visualDensity: VisualDensity.compact),
                            const SizedBox(width: 7),
                            ChoiceChip(label: const Text('Tasks', style: TextStyle(fontSize: 12)), selected: _histFilter == 1, onSelected: (_) => setState(() => _histFilter = 1), visualDensity: VisualDensity.compact),
                            const SizedBox(width: 7),
                            ChoiceChip(label: const Text('Papers', style: TextStyle(fontSize: 12)), selected: _histFilter == 2, onSelected: (_) => setState(() => _histFilter = 2), visualDensity: VisualDensity.compact),
                            const SizedBox(width: 7),
                            ChoiceChip(label: const Text('Speakers', style: TextStyle(fontSize: 12)), selected: _histFilter == 3, onSelected: (_) => setState(() => _histFilter = 3), visualDensity: VisualDensity.compact),
                          ],
                        ),
                      ),
                    ),
                    PopupMenuButton<int>(
                      icon: const Icon(Icons.sort_outlined, size: 19),
                      tooltip: 'Sort sessions',
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      onSelected: (v) => setState(() => _histSort = v),
                      itemBuilder: (context) => const [
                        PopupMenuItem(value: 0, child: Text('Newest first')),
                        PopupMenuItem(value: 1, child: Text('Oldest first')),
                        PopupMenuItem(value: 2, child: Text('Title A–Z')),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Builder(
              builder: (context) {
                final sessions = _visibleSessions();
                if (sessions.isEmpty) {
                  return EmptyState(
                    icon: Icons.archive_outlined,
                    title: _searchController.text.isNotEmpty || _histFilter != 0
                        ? 'No matching sessions'
                        : 'Archive is empty',
                    body: 'Saved sessions appear here with reference hashes, citations, and speaker turns.',
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: sessions.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final session = sessions[index];
                    return Dismissible(
                      key: Key(session.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.error,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text('Delete', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                            SizedBox(width: 8),
                            Icon(Icons.delete_outline, color: Colors.white),
                          ],
                        ),
                      ),
                      onDismissed: (_) {
                        _deleteSession(session.id);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Deleted "${session.title}"')),
                        );
                      },
                      child: LabCard(
                        onTap: () => Navigator.pop(context, session),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 38,
                                  height: 38,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                                  ),
                                  child: Icon(
                                    session.isVirtualCall ? Icons.video_call_outlined : Icons.science_outlined,
                                    size: 18,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                                const SizedBox(width: 11),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        session.title,
                                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        '${session.createdAt.toLocal().toString().split('.')[0]} · ${formatHMS(session.durationSeconds)}',
                                        style: TextStyle(fontSize: 11, color: theme.colorScheme.outline, fontFeatures: const [FontFeature.tabularFigures()]),
                                      ),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.chevron_right, size: 18),
                              ],
                            ),
                            if (session.summary?.scientificHypothesis.isNotEmpty == true) ...[
                              const SizedBox(height: 10),
                              Text(
                                session.summary!.scientificHypothesis,
                                style: TextStyle(fontSize: 12.5, fontStyle: FontStyle.italic, height: 1.45, color: theme.colorScheme.onSurface.withValues(alpha: 0.8)),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 7,
                              runSpacing: 7,
                              children: [
                                if (session.isDeIdentified)
                                  StatusPill(icon: Icons.shield_outlined, label: 'Masked', color: theme.colorScheme.primary),
                                if (session.audioSha256 != null)
                                  StatusPill(icon: Icons.verified_outlined, label: 'SHA-256', color: theme.colorScheme.secondary),
                                if (session.citations.isNotEmpty)
                                  StatusPill(icon: Icons.library_books_outlined, label: '${session.citations.length} papers', color: theme.colorScheme.secondary),
                                if (session.speakerTurns.isNotEmpty)
                                  StatusPill(icon: Icons.record_voice_over_outlined, label: '${session.speakerTurns.length} turns', color: theme.colorScheme.tertiary),
                                if (session.actionItems.isNotEmpty)
                                  StatusPill(icon: Icons.fact_check_outlined, label: '${session.actionItems.length} tasks', color: theme.colorScheme.primary),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}
