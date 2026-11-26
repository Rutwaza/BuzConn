import 'package:flutter/material.dart';

import '../../core/i18n/tr.dart';
import '../../core/services/r2_storage_service.dart';
import '../../core/theme/colors.dart';
import '../../core/widgets/verified_badge.dart';

/// "Get verified": shows the checklist from the server (functions/
/// verification.js) and sends the request to the admins when every item is ✓.
/// [kind] is 'user' (your account) or 'page' (with [targetId] = page id).
Future<void> showVerificationSheet(BuildContext context,
    {required String kind, String? targetId}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (_) => _VerificationSheet(kind: kind, targetId: targetId),
  );
}

class _VerificationSheet extends StatefulWidget {
  const _VerificationSheet({required this.kind, this.targetId});
  final String kind;
  final String? targetId;

  @override
  State<_VerificationSheet> createState() => _VerificationSheetState();
}

class _VerificationSheetState extends State<_VerificationSheet> {
  late Future<Map<String, dynamic>> _check = _load();
  final _note = TextEditingController();
  bool _sending = false;

  Map<String, Object?> get _args => {
        'kind': widget.kind,
        if (widget.targetId != null) 'targetId': widget.targetId,
      };

  Future<Map<String, dynamic>> _load() =>
      R2StorageService.instance.callFunction('checkVerification', _args);

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await R2StorageService.instance.callFunction('requestVerification', {
        ..._args,
        'note': _note.text.trim(),
      });
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(SnackBar(
          content: Text(tr('Request sent. The team will review it soon.'))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: FutureBuilder<Map<String, dynamic>>(
        future: _check,
        builder: (context, snap) {
          if (snap.hasError) {
            final msg = snap.error.toString();
            return Column(mainAxisSize: MainAxisSize.min, children: [
              const VerifiedBadge(size: 48),
              const SizedBox(height: 12),
              Text(msg.contains('already')
                  ? tr('Already verified ✓')
                  : msg),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => setState(() => _check = _load()),
                child: Text(tr('Try again')),
              ),
            ]);
          }
          if (!snap.hasData) {
            return const SizedBox(
                height: 220, child: Center(child: CircularProgressIndicator()));
          }
          final d = snap.data!;
          final checks = (d['checks'] as List? ?? [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          final eligible = d['eligible'] == true;
          final req = d['request'] is Map
              ? Map<String, dynamic>.from(d['request'] as Map)
              : null;
          final status = req?['status']?.toString();
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const VerifiedBadge(size: 30),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.kind == 'page'
                          ? '${tr('Verify')} ${d['targetName'] ?? ''}'
                          : tr('Get verified'),
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w800),
                    ),
                  ),
                ]),
                const SizedBox(height: 6),
                Text(
                  tr('The blue ✓ tells people this is the real, trusted account. The Duhuze team checks every request.'),
                  style: const TextStyle(color: AppColors.grey),
                ),
                const SizedBox(height: 14),
                _Progress(
                  done: checks.where((c) => c['ok'] == true).length,
                  total: checks.length,
                ),
                const SizedBox(height: 8),
                for (final c in checks) _CheckRow(c: c),
                const SizedBox(height: 10),
                if (status == 'pending')
                  _Banner(
                    icon: Icons.hourglass_top_rounded,
                    color: AppColors.primary,
                    text: tr('Your request is waiting for review.'),
                  )
                else ...[
                  if (status == 'rejected')
                    _Banner(
                      icon: Icons.info_outline_rounded,
                      color: Colors.orange,
                      text:
                          '${tr('Last request was not approved.')} ${req?['reviewNote'] ?? ''}',
                    ),
                  if (eligible) ...[
                    TextField(
                      controller: _note,
                      maxLength: 500,
                      maxLines: 3,
                      decoration: InputDecoration(
                        labelText: tr('Anything the team should know? (optional)'),
                        hintText: tr('e.g. your website, a news article, your business registration'),
                      ),
                    ),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _sending ? null : _send,
                        icon: const Icon(Icons.verified_rounded),
                        label: Text(tr('Request verification')),
                      ),
                    ),
                  ] else
                    _Banner(
                      icon: Icons.trending_up_rounded,
                      color: AppColors.grey,
                      text: tr('Finish the items above, then come back to send your request.'),
                    ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(children: [
        Icon(icon, color: color),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ]),
    );
  }
}

/// "5 of 9 done" with a bar.
class _Progress extends StatelessWidget {
  const _Progress({required this.done, required this.total});
  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    final v = total == 0 ? 0.0 : done / total;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text('$done ${tr('of')} $total ${tr('done')}',
            style: const TextStyle(fontWeight: FontWeight.w800)),
        const Spacer(),
        Text('${(v * 100).round()}%',
            style: const TextStyle(color: AppColors.grey, fontSize: 12)),
      ]),
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(99),
        child: LinearProgressIndicator(
          value: v,
          minHeight: 8,
          color: done == total ? AppColors.success : AppColors.primary,
          backgroundColor: AppColors.grey.withValues(alpha: 0.18),
        ),
      ),
    ]);
  }
}

/// One criterion: ✓ or ○, the numbers, and what to do if it's not met.
class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.c});
  final Map<String, dynamic> c;

  @override
  Widget build(BuildContext context) {
    final ok = c['ok'] == true;
    final detail = (c['detail'] ?? '').toString();
    final tip = (c['tip'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(
          ok ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
          color: ok ? AppColors.success : AppColors.grey,
          size: 22,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(tr(c['label'].toString()),
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        decoration: ok ? null : TextDecoration.none)),
              ),
              if (detail.isNotEmpty)
                Text(detail,
                    style: TextStyle(
                        fontSize: 12,
                        color: ok ? AppColors.success : AppColors.grey,
                        fontWeight: FontWeight.w700)),
            ]),
            if (!ok && tip.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(tr(tip),
                    style: const TextStyle(fontSize: 12.5, color: AppColors.grey)),
              ),
          ]),
        ),
      ]),
    );
  }
}
