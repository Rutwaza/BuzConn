import 'package:flutter/material.dart';

import '../../core/i18n/tr.dart';
import '../../core/theme/colors.dart';
import 'billing_service.dart';
import 'pay_sheet.dart';

/// "Get another page": how many pages you have, the price of one more,
/// and the button to pay. Returns true when a new slot was bought.
Future<bool> showPageSlotsSheet(BuildContext context) async {
  final bought = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 520),
    builder: (_) => const _PageSlotsSheet(),
  );
  return bought == true;
}

class _PageSlotsSheet extends StatefulWidget {
  const _PageSlotsSheet();

  @override
  State<_PageSlotsSheet> createState() => _PageSlotsSheetState();
}

class _PageSlotsSheetState extends State<_PageSlotsSheet> {
  late final Future<BillingInfo> _info = BillingService.instance.info();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: FutureBuilder<BillingInfo>(
        future: _info,
        builder: (context, snap) {
          if (snap.hasError) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Text('${snap.error}', textAlign: TextAlign.center),
            );
          }
          if (!snap.hasData) {
            return const SizedBox(
                height: 200, child: Center(child: CircularProgressIndicator()));
          }
          final info = snap.data!;
          final s = info.pages;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.add_business_rounded,
                  size: 44, color: AppColors.primary),
              const SizedBox(height: 10),
              Text(
                s.canCreate ? tr('You can create a page') : tr('Get another page'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                tr('Your first page is free. Each extra page is paid once and is yours for good.'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.grey),
              ),
              const SizedBox(height: 16),
              _SlotsBar(used: s.used, total: s.total),
              const SizedBox(height: 14),
              _Line(Icons.check_rounded, tr('Its own followers, posts, shop and orders')),
              _Line(Icons.check_rounded, tr('Its own team (admins and editors)')),
              _Line(Icons.check_rounded, tr('Can be verified like any page')),
              _Line(Icons.info_outline_rounded,
                  tr('Hiding a page frees its place; showing it again needs a free place.')),
              const SizedBox(height: 16),
              if (s.canCreate)
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  child: Text(tr('Continue')),
                )
              else
                FilledButton.icon(
                  onPressed: () async {
                    final nav = Navigator.of(context);
                    final paid = await showPaySheet(
                      context,
                      item: 'page_slot',
                      icon: Icons.add_business_rounded,
                      title: tr('One more page'),
                      subtitle: tr('You can create a new page right after paying.'),
                      amount: info.pageSlotPrice,
                    );
                    if (paid) nav.pop(true);
                  },
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  icon: const Icon(Icons.lock_open_rounded, size: 18),
                  label: Text('${tr('Get one more page')} · ${rwf(info.pageSlotPrice)}'),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _SlotsBar extends StatelessWidget {
  const _SlotsBar({required this.used, required this.total});
  final int used;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(tr('Your pages'), style: const TextStyle(fontWeight: FontWeight.w700)),
          const Spacer(),
          Text('$used / $total',
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          for (var i = 0; i < total.clamp(1, 12); i++)
            Expanded(
              child: Container(
                height: 8,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(9),
                  color: i < used
                      ? AppColors.primary
                      : AppColors.grey.withValues(alpha: 0.25),
                ),
              ),
            ),
        ]),
      ]),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: AppColors.primary),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13.5))),
      ]),
    );
  }
}

/// "Boost post": choose 3 / 7 / 14 days, then pay.
Future<void> showBoostSheet(BuildContext context, {required String postId}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 520),
    builder: (_) => _BoostSheet(postId: postId),
  );
}

class _BoostSheet extends StatefulWidget {
  const _BoostSheet({required this.postId});
  final String postId;

  @override
  State<_BoostSheet> createState() => _BoostSheetState();
}

class _BoostSheetState extends State<_BoostSheet> {
  late final Future<BillingInfo> _info = BillingService.instance.info();
  String? _selected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: FutureBuilder<BillingInfo>(
        future: _info,
        builder: (context, snap) {
          if (snap.hasError) {
            return Padding(
                padding: const EdgeInsets.all(24), child: Text('${snap.error}'));
          }
          if (!snap.hasData) {
            return const SizedBox(
                height: 200, child: Center(child: CircularProgressIndicator()));
          }
          final packages = snap.data!.boostPackages;
          _selected ??= packages.length > 1 ? packages[1].id : packages.firstOrNull?.id;
          final chosen = packages.where((p) => p.id == _selected).firstOrNull;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.rocket_launch_rounded, size: 42, color: AppColors.primary),
              const SizedBox(height: 10),
              Text(tr('Boost this post'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text(
                tr('Your post shows near the top of For You for everyone, marked "Sponsored". Pick how long.'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.grey),
              ),
              const SizedBox(height: 16),
              for (final p in packages)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: _selected == p.id
                        ? AppColors.primary.withValues(alpha: 0.10)
                        : Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(
                        color: _selected == p.id
                            ? AppColors.primary
                            : AppColors.grey.withValues(alpha: 0.3),
                        width: _selected == p.id ? 2 : 1,
                      ),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => setState(() => _selected = p.id),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(children: [
                          Icon(
                            _selected == p.id
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_off_rounded,
                            color: AppColors.primary,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text('${p.days} ${tr('days')}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800, fontSize: 15)),
                          ),
                          Text(rwf(p.price),
                              style: const TextStyle(fontWeight: FontWeight.w800)),
                        ]),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: chosen == null
                    ? null
                    : () async {
                        final nav = Navigator.of(context);
                        final messenger = ScaffoldMessenger.of(context);
                        final paid = await showPaySheet(
                          context,
                          item: 'boost',
                          postId: widget.postId,
                          packageId: chosen.id,
                          icon: Icons.rocket_launch_rounded,
                          title: '${tr('Boost for')} ${chosen.days} ${tr('days')}',
                          subtitle: tr('Your post will show as Sponsored in For You.'),
                          amount: chosen.price,
                        );
                        if (paid) {
                          nav.pop();
                          messenger.showSnackBar(
                              SnackBar(content: Text(tr('Your post is boosted 🚀'))));
                        }
                      },
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.rocket_launch_rounded, size: 18),
                label: Text(chosen == null
                    ? tr('Boost')
                    : '${tr('Boost')} · ${rwf(chosen.price)}'),
              ),
            ],
          );
        },
      ),
    );
  }
}
