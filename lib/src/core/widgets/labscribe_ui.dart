import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../workflow/session_workflow.dart';

/// Reusable premium UI primitives for LabScribe AI.
/// Keeps every dashboard visually coherent without duplicating styles.

String formatHMS(int totalSeconds) {
  final h = (totalSeconds ~/ 3600).toString().padLeft(2, '0');
  final m = ((totalSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
  final s = (totalSeconds % 60).toString().padLeft(2, '0');
  return '$h:$m:$s';
}

String formatMS(int totalSeconds) {
  final m = (totalSeconds ~/ 60).toString().padLeft(2, '0');
  final s = (totalSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// Uppercase tracking label used above every section.
class SectionLabel extends StatelessWidget {
  final String text;
  final IconData? icon;
  final Widget? trailing;
  const SectionLabel(this.text, {super.key, this.icon, this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
        ],
        Expanded(
          child: Text(
            text.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              color: theme.colorScheme.outline,
            ),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

/// Bordered card with consistent 20px radius and soft inner padding.
class LabCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final VoidCallback? onTap;
  const LabCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final card = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? theme.cardTheme.color,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: child,
    );
    if (onTap == null) return card;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: card,
    );
  }
}

/// Small tinted pill for status metadata and counts.
class StatusPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const StatusPill({super.key, required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: color),
          ),
        ],
      ),
    );
  }
}

/// 4-stage AI pipeline indicator: Capture → Transcribe → Synthesize → Sealed.
class PipelineSteps extends StatelessWidget {
  final int activeStage; // 0 idle, 1 transcribing, 2 scrub/summarize, 3 done
  final bool hasError;
  const PipelineSteps({super.key, required this.activeStage, this.hasError = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const labels = ['Capture', 'Transcribe', 'Synthesize', 'Sealed'];
    const icons = [Icons.mic, Icons.graphic_eq, Icons.auto_awesome, Icons.verified];
    return Row(
      children: List.generate(4, (i) {
        final reached = activeStage >= (i + 1);
        final current = activeStage == (i + 1);
        final color = hasError && current
            ? theme.colorScheme.error
            : reached
                ? theme.colorScheme.primary
                : theme.colorScheme.outline;
        return Expanded(
          child: Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: reached
                      ? theme.colorScheme.primary.withValues(alpha: 0.14)
                      : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
                  border: Border.all(color: color.withValues(alpha: 0.5)),
                ),
                child: Icon(icons[i], size: 13, color: color),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  labels[i],
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: current ? FontWeight.w800 : FontWeight.w600,
                    color: color,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (i < 3)
                Expanded(
                  child: Container(
                    height: 2,
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      color: activeStage > (i + 1)
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant,
                    ),
                  ),
                ),
            ],
          ),
        );
      }),
    );
  }
}

/// Premium empty state with tinted icon, title, body and CTAs.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.25),
                  ),
                ),
                child: Icon(icon, size: 30, color: theme.colorScheme.primary),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                body,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              if (primaryLabel != null) ...[
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: onPrimary,
                  icon: const Icon(Icons.auto_awesome, size: 16),
                  label: Text(primaryLabel!),
                ),
              ],
              if (secondaryLabel != null) ...[
                const SizedBox(height: 8),
                TextButton(onPressed: onSecondary, child: Text(secondaryLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Single metric tile for session stats row.
class MetricTile extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final Color color;
  const MetricTile({
    super.key,
    required this.icon,
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Column(
          children: [
            Icon(icon, size: 17, color: color),
            const SizedBox(height: 6),
            Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              label,
              style: TextStyle(fontSize: 10.5, color: theme.colorScheme.outline),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// Brand mark used in AppBar and dialogs.
class BrandMark extends StatelessWidget {
  final double size;
  const BrandMark({super.key, this.size = 34});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.32),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.primary,
            theme.colorScheme.secondary,
          ],
        ),
      ),
      child: Icon(Icons.biotech, color: theme.colorScheme.onPrimary, size: size * 0.55),
    );
  }
}

/// Grouped settings row (icon + title + subtitle + trailing switch/action).
class SettingRow extends StatelessWidget {  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final Widget trailing;
  const SettingRow({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: iconColor.withValues(alpha: 0.12),
            ),
            child: Icon(icon, size: 17, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 11.5, color: theme.colorScheme.outline),
                ),
              ],
            ),
          ),
          trailing,
        ],
      ),
    );
  }
}

/// Horizontal stacked bar showing speaking-time share per participant,
/// in the style of Gong/Fireflies talk-time analytics.
class TalkTimeBar extends StatelessWidget {
  final Map<String, int> secondsBySpeaker;
  final Map<String, Color> colorBySpeaker;
  const TalkTimeBar({
    super.key,
    required this.secondsBySpeaker,
    required this.colorBySpeaker,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = secondsBySpeaker.values.fold<int>(0, (a, b) => a + b);
    if (total <= 0) return const SizedBox.shrink();
    final entries = secondsBySpeaker.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: Row(
            children: entries.map((e) {
              final frac = e.value / total;
              final color = colorBySpeaker[e.key] ?? theme.colorScheme.primary;
              return Expanded(
                flex: (frac * 1000).round().clamp(1, 1000).toInt(),
                child: Container(height: 8, color: color),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 6,
          children: entries.map((e) {
            final color = colorBySpeaker[e.key] ?? theme.colorScheme.primary;
            final pct = (e.value / total * 100).round();
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
                const SizedBox(width: 5),
                Text(
                  '${e.key} · $pct%',
                  style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            );
          }).toList(),
        ),
      ],
    );
  }
}


/// Amber strip marking results as built-in sample content.
/// Shown whenever visible analysis came from the sample instead of the
/// user's recording, so demo output can never be mistaken for real results.
class DemoBanner extends StatelessWidget {
  final VoidCallback onSetup;
  const DemoBanner({super.key, required this.onSetup});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.tertiary.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Icon(Icons.science_outlined, size: 17, color: theme.colorScheme.tertiary),
          const SizedBox(width: 9),
          const Expanded(
            child: Text(
              'Sample data — a built-in example, not your recording.',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, height: 1.35),
            ),
          ),
          FilledButton.tonalIcon(
            onPressed: onSetup,
            icon: const Icon(Icons.key_outlined, size: 13),
            label: const Text('Set up', style: TextStyle(fontSize: 12)),
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
          ),
        ],
      ),
    );
  }
}

/// Animated level-meter bars shown while recording, in the style of
/// professional recorder apps. Pure presentation — no audio analysis.
class RecordingBars extends StatefulWidget {
  final bool active;
  const RecordingBars({super.key, required this.active});

  @override
  State<RecordingBars> createState() => _RecordingBarsState();
}

class _RecordingBarsState extends State<RecordingBars> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(RecordingBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(28, (i) {
            final phase = _controller.value * 6.283 + i * 0.55;
            final wave = (math.sin(phase) + 1) / 2;
            final h = widget.active ? 4.0 + 11.0 * wave : 4.0;
            final color = widget.active
                ? theme.colorScheme.primary.withValues(alpha: 0.45 + 0.4 * wave)
                : theme.colorScheme.outlineVariant;
            return Container(
              width: 3,
              height: h,
              margin: const EdgeInsets.symmetric(horizontal: 1.6),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(2), color: color),
            );
          }),
        );
      },
    );
  }
}

/// Five-step session stepper (Capture → Transcribe → Synthesize → Review →
/// Export) shown in the persistent session header. Gives every tab a shared
/// sense of progress through one continuous workflow.
class StageStepper extends StatelessWidget {
  final SessionStage current;
  const StageStepper({super.key, required this.current});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const order = SessionWorkflow.visible;
    final currentIdx = current == SessionStage.done ? order.length : order.indexOf(current);
    return Row(
      children: List.generate(order.length * 2 - 1, (i) {
        if (i.isOdd) {
          final done = (i ~/ 2) < currentIdx;
          return Expanded(
            child: Container(
              height: 2,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                color: done
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
              ),
            ),
          );
        }
        final idx = i ~/ 2;
        final stage = order[idx];
        final done = idx < currentIdx;
        final isCurrent = idx == currentIdx;
        final color = done
            ? theme.colorScheme.primary
            : (isCurrent ? SessionWorkflow.color(stage) : theme.colorScheme.outline);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done || isCurrent
                    ? color.withValues(alpha: 0.14)
                    : Colors.transparent,
                border: Border.all(color: color.withValues(alpha: 0.6)),
              ),
              child: Icon(
                done ? Icons.check : SessionWorkflow.icon(stage),
                size: 12,
                color: color,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              SessionWorkflow.label(stage),
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: isCurrent ? FontWeight.w800 : FontWeight.w600,
                color: done || isCurrent ? theme.colorScheme.onSurface : theme.colorScheme.outline,
              ),
            ),
          ],
        );
      }),
    );
  }
}

/// Standard page header template used by every review tab:
/// title + subtitle on the left, actions on the right.
class PageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  const PageHeader({super.key, required this.title, this.subtitle, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 19)),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(subtitle!, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline)),
              ],
            ],
          ),
        ),
        const SizedBox(width: 10),
        ...actions,
      ],
    );
  }
}
