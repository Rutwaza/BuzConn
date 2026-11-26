import 'package:flutter/material.dart';

import '../i18n/tr.dart';
import '../theme/colors.dart';

/// A page's opening hours, saved on the page as
///   hours: {"1": "08:00-18:00", ..., "7": ""}
/// 1 = Monday ... 7 = Sunday (like DateTime.weekday). "" = closed that day.
/// A page without `hours` shows nothing (we don't guess).
class OpeningHours {
  OpeningHours(this.days);

  /// weekday -> (open minutes, close minutes) or null when closed.
  final Map<int, (int, int)?> days;

  static const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  static OpeningHours? fromData(Object? raw) {
    if (raw is! Map || raw.isEmpty) return null;
    final days = <int, (int, int)?>{};
    for (var d = 1; d <= 7; d++) {
      days[d] = _parse(raw['$d']?.toString() ?? '');
    }
    if (days.values.every((v) => v == null)) return null;
    return OpeningHours(days);
  }

  static (int, int)? _parse(String s) {
    final m = RegExp(r'^(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})$').firstMatch(s.trim());
    if (m == null) return null;
    final open = int.parse(m[1]!) * 60 + int.parse(m[2]!);
    final close = int.parse(m[3]!) * 60 + int.parse(m[4]!);
    if (open >= 24 * 60 || close > 24 * 60) return null;
    return (open, close);
  }

  static String fmt(int minutes) {
    final h = (minutes ~/ 60) % 24;
    final m = minutes % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  Map<String, String> toData() => {
        for (var d = 1; d <= 7; d++)
          '$d': days[d] == null ? '' : '${fmt(days[d]!.$1)}-${fmt(days[d]!.$2)}',
      };

  /// Open right now? Handles nights past midnight (e.g. 18:00-02:00).
  bool isOpenAt(DateTime t) {
    final now = t.hour * 60 + t.minute;
    final today = days[t.weekday];
    if (today != null && _inside(today, now)) return true;
    // Yesterday's hours that run past midnight.
    final y = days[t.weekday == 1 ? 7 : t.weekday - 1];
    if (y != null && y.$2 <= y.$1 && now < y.$2) return true;
    return false;
  }

  static bool _inside((int, int) h, int now) {
    final (open, close) = h;
    if (close == open) return true; // 24 hours
    if (close > open) return now >= open && now < close;
    return now >= open; // closes after midnight
  }

  /// "Open now · until 18:00" / "Closed · opens 08:00" / "Closed · opens Mon 08:00"
  (bool, String) status([DateTime? at]) {
    final t = at ?? DateTime.now();
    final now = t.hour * 60 + t.minute;
    if (isOpenAt(t)) {
      final today = days[t.weekday];
      final y = days[t.weekday == 1 ? 7 : t.weekday - 1];
      int? until;
      if (today != null && _inside(today, now)) {
        until = today.$1 == today.$2 ? null : today.$2;
      } else if (y != null) {
        until = y.$2;
      }
      return (true, until == null ? tr('Open 24 hours') : '${tr('Open now')} · ${tr('until')} ${fmt(until)}');
    }
    final today = days[t.weekday];
    if (today != null && now < today.$1) {
      return (false, '${tr('Closed')} · ${tr('opens')} ${fmt(today.$1)}');
    }
    for (var i = 1; i <= 7; i++) {
      final d = ((t.weekday - 1 + i) % 7) + 1;
      final h = days[d];
      if (h != null) {
        final when = i == 1 ? tr('tomorrow') : tr(dayNames[d - 1]);
        return (false, '${tr('Closed')} · ${tr('opens')} $when ${fmt(h.$1)}');
      }
    }
    return (false, tr('Closed'));
  }
}

/// Small green/grey "Open now · until 18:00" chip. Nothing if no hours.
class OpenStatusChip extends StatelessWidget {
  const OpenStatusChip({super.key, required this.hours, this.compact = false});
  final Object? hours;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final h = OpeningHours.fromData(hours);
    if (h == null) return const SizedBox.shrink();
    final (open, text) = h.status();
    final color = open ? AppColors.success : AppColors.grey;
    final label = compact ? (open ? tr('Open now') : tr('Closed')) : text;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.schedule_rounded, size: 13, color: color),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: color)),
      ]),
    );
  }
}

/// The week's hours as a small table (page profile).
class OpeningHoursTable extends StatelessWidget {
  const OpeningHoursTable({super.key, required this.hours});
  final Object? hours;

  @override
  Widget build(BuildContext context) {
    final h = OpeningHours.fromData(hours);
    if (h == null) return const SizedBox.shrink();
    final today = DateTime.now().weekday;
    return Column(children: [
      for (var d = 1; d <= 7; d++)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            SizedBox(
              width: 56,
              child: Text(tr(OpeningHours.dayNames[d - 1]),
                  style: TextStyle(
                      fontWeight: d == today ? FontWeight.w800 : FontWeight.w500)),
            ),
            Text(
              h.days[d] == null
                  ? tr('Closed')
                  : h.days[d]!.$1 == h.days[d]!.$2
                      ? tr('Open 24 hours')
                      : '${OpeningHours.fmt(h.days[d]!.$1)} – ${OpeningHours.fmt(h.days[d]!.$2)}',
              style: TextStyle(
                color: h.days[d] == null ? AppColors.grey : null,
                fontWeight: d == today ? FontWeight.w800 : FontWeight.w500,
              ),
            ),
          ]),
        ),
    ]);
  }
}

/// Edit opening hours. Returns the new `hours` map, {} to remove them,
/// or null when cancelled.
Future<Map<String, String>?> showOpeningHoursEditor(BuildContext context, Object? current) {
  return showModalBottomSheet<Map<String, String>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (_) => _HoursEditor(initial: OpeningHours.fromData(current)),
  );
}

class _HoursEditor extends StatefulWidget {
  const _HoursEditor({this.initial});
  final OpeningHours? initial;

  @override
  State<_HoursEditor> createState() => _HoursEditorState();
}

class _HoursEditorState extends State<_HoursEditor> {
  late final Map<int, (int, int)?> _days = {
    for (var d = 1; d <= 7; d++)
      d: widget.initial == null ? (d <= 6 ? (8 * 60, 18 * 60) : null) : widget.initial!.days[d],
  };

  Future<int?> _pick(int minutes) async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: (minutes ~/ 60) % 24, minute: minutes % 60),
      builder: (c, child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    return t == null ? null : t.hour * 60 + t.minute;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(tr('Opening hours'),
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(tr('People see "Open now" or "Closed" on your page and in Discover.'),
            style: const TextStyle(color: AppColors.grey)),
        const SizedBox(height: 10),
        for (var d = 1; d <= 7; d++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              SizedBox(
                width: 52,
                child: Text(tr(OpeningHours.dayNames[d - 1]),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              Switch(
                value: _days[d] != null,
                onChanged: (on) => setState(() => _days[d] = on
                    ? (_days[d == 1 ? 7 : d - 1] ?? (8 * 60, 18 * 60))
                    : null),
              ),
              const SizedBox(width: 6),
              if (_days[d] == null)
                Text(tr('Closed'), style: const TextStyle(color: AppColors.grey))
              else ...[
                _TimeButton(
                  text: OpeningHours.fmt(_days[d]!.$1),
                  onTap: () async {
                    final v = await _pick(_days[d]!.$1);
                    if (v != null) setState(() => _days[d] = (v, _days[d]!.$2));
                  },
                ),
                const Text('  –  '),
                _TimeButton(
                  text: OpeningHours.fmt(_days[d]!.$2),
                  onTap: () async {
                    final v = await _pick(_days[d]!.$2);
                    if (v != null) setState(() => _days[d] = (_days[d]!.$1, v));
                  },
                ),
              ],
            ]),
          ),
        const SizedBox(height: 6),
        Wrap(spacing: 8, children: [
          ActionChip(
            avatar: const Icon(Icons.copy_all_rounded, size: 16),
            label: Text(tr('Copy Monday to all weekdays')),
            onPressed: () => setState(() {
              for (var d = 2; d <= 5; d++) {
                _days[d] = _days[1];
              }
            }),
          ),
          ActionChip(
            avatar: const Icon(Icons.all_inclusive_rounded, size: 16),
            label: Text(tr('Open 24/7')),
            onPressed: () => setState(() {
              for (var d = 1; d <= 7; d++) {
                _days[d] = (0, 0);
              }
            }),
          ),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          TextButton(
            onPressed: () => Navigator.pop(context, <String, String>{}),
            child: Text(tr('Remove hours')),
          ),
          const Spacer(),
          FilledButton(
            onPressed: () => Navigator.pop(context, OpeningHours(_days).toData()),
            child: Text(tr('Save')),
          ),
        ]),
      ]),
    );
  }
}

class _TimeButton extends StatelessWidget {
  const _TimeButton({required this.text, required this.onTap});
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10),
      ),
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700)),
    );
  }
}
