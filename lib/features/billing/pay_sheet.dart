import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/i18n/tr.dart';
import '../../core/theme/colors.dart';
import 'billing_service.dart';

/// The one payment screen for everything paid to Duhuze.
///
///   1. choose MTN MoMo or Airtel Money, check the number
///   2. the server makes the payment (functions/billing.js startPurchase)
///   3. "Enter your PIN on your phone" -> waits until payments/{id} is paid
///
/// While the gateway (IremboPay) is not switched on, step 2 answers
/// "not_ready" and this shows "Payments are coming soon" (nothing charged).
/// Returns true when the item was paid and given.
Future<bool> showPaySheet(
  BuildContext context, {
  required String item,
  required String title,
  required String subtitle,
  required int amount,
  required IconData icon,
  String? postId,
  String? packageId,
}) async {
  final paid = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 520),
    builder: (_) => _PaySheet(
      item: item,
      title: title,
      subtitle: subtitle,
      amount: amount,
      icon: icon,
      postId: postId,
      packageId: packageId,
    ),
  );
  return paid == true;
}

enum _Step { choose, starting, notReady, waiting, done, failed }

class _PaySheet extends StatefulWidget {
  const _PaySheet({
    required this.item,
    required this.title,
    required this.subtitle,
    required this.amount,
    required this.icon,
    this.postId,
    this.packageId,
  });

  final String item;
  final String title;
  final String subtitle;
  final int amount;
  final IconData icon;
  final String? postId;
  final String? packageId;

  @override
  State<_PaySheet> createState() => _PaySheetState();
}

class _PaySheetState extends State<_PaySheet> {
  _Step _step = _Step.choose;
  String _network = 'MTN';
  late final _phone = TextEditingController(
      text: FirebaseAuth.instance.currentUser?.phoneNumber ?? '');
  String? _error;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;

  @override
  void dispose() {
    _sub?.cancel();
    _phone.dispose();
    super.dispose();
  }

  bool get _phoneOk =>
      RegExp(r'^(\+?250|0)?7[2389]\d{7}$').hasMatch(_phone.text.replaceAll(' ', ''));

  /// "0788 123 456" -> "250788123456" (what gateways expect).
  String get _phoneIntl {
    var p = _phone.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (p.startsWith('0')) p = '250${p.substring(1)}';
    if (!p.startsWith('250')) p = '250$p';
    return p;
  }

  Future<void> _pay() async {
    setState(() {
      _step = _Step.starting;
      _error = null;
    });
    try {
      final r = await BillingService.instance.start(
        item: widget.item,
        postId: widget.postId,
        packageId: widget.packageId,
        phone: _phoneIntl,
        network: _network,
      );
      if (!mounted) return;
      if (r['status'] == 'not_ready') {
        setState(() => _step = _Step.notReady);
        return;
      }
      final url = r['url']?.toString();
      if (r['kind'] == 'link' && url != null && url.isNotEmpty) {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      }
      _listen(r['paymentId'].toString());
      setState(() => _step = _Step.waiting);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _step = _Step.failed;
        _error = e.toString().replaceFirst('HttpException: ', '');
      });
    }
  }

  void _listen(String id) {
    _sub?.cancel();
    _sub = FirebaseFirestore.instance
        .collection('payments')
        .doc(id)
        .snapshots()
        .listen((d) {
      final status = d.data()?['status'];
      if (!mounted) return;
      if (status == 'paid') {
        setState(() => _step = _Step.done);
      } else if (status == 'failed') {
        setState(() {
          _step = _Step.failed;
          _error = tr('The payment did not go through. Nothing was taken.');
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        child: switch (_step) {
          _Step.choose || _Step.starting => _choose(context),
          _Step.notReady => _Result(
              icon: Icons.rocket_launch_rounded,
              color: AppColors.primary,
              title: tr('Payments are coming soon'),
              text: tr(
                  'We are finishing the connection with IremboPay (MoMo, Airtel Money and cards). Nothing was charged. You will be able to pay right here very soon.'),
              button: tr('OK'),
              onTap: () => Navigator.pop(context, false),
            ),
          _Step.waiting => _Result(
              icon: Icons.phone_iphone_rounded,
              color: AppColors.primary,
              busy: true,
              title: tr('Check your phone'),
              text:
                  '${tr('Enter your PIN to pay')} ${rwf(widget.amount)}. ${tr('This screen updates by itself.')}',
              button: tr('Close'),
              onTap: () => Navigator.pop(context, false),
            ),
          _Step.done => _Result(
              icon: Icons.check_circle_rounded,
              color: AppColors.success,
              title: tr('Paid. Thank you!'),
              text: widget.subtitle,
              button: tr('Done'),
              onTap: () => Navigator.pop(context, true),
            ),
          _Step.failed => _Result(
              icon: Icons.error_outline_rounded,
              color: AppColors.error,
              title: tr('Payment not done'),
              text: _error ?? '',
              button: tr('Try again'),
              onTap: () => setState(() => _step = _Step.choose),
            ),
        },
      ),
    );
  }

  Widget _choose(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final busy = _step == _Step.starting;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // What you're paying for.
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(colors: [
              AppColors.primary.withValues(alpha: isDark ? 0.30 : 0.14),
              AppColors.secondary.withValues(alpha: isDark ? 0.20 : 0.10),
            ]),
          ),
          child: Row(children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: AppColors.primary,
              child: Icon(widget.icon, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.title,
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                Text(widget.subtitle,
                    style: const TextStyle(fontSize: 12.5, color: AppColors.grey)),
              ]),
            ),
            Text(rwf(widget.amount),
                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
          ]),
        ),
        const SizedBox(height: 16),
        Text(tr('Pay with'), style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Row(children: [
          for (final n in const [
            ('MTN', 'MTN MoMo', Color(0xFFFFCB05)),
            ('AIRTEL', 'Airtel Money', Color(0xFFE40000)),
          ]) ...[
            Expanded(
              child: _NetworkCard(
                label: n.$2,
                color: n.$3,
                selected: _network == n.$1,
                onTap: busy ? null : () => setState(() => _network = n.$1),
              ),
            ),
            if (n.$1 == 'MTN') const SizedBox(width: 10),
          ],
        ]),
        const SizedBox(height: 14),
        TextField(
          controller: _phone,
          enabled: !busy,
          keyboardType: TextInputType.phone,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: tr('Phone number that pays'),
            hintText: '07XX XXX XXX',
            prefixIcon: const Icon(Icons.phone_rounded),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          tr('You will get a prompt on this phone to enter your PIN. Payments go through IremboPay.'),
          style: const TextStyle(fontSize: 12, color: AppColors.grey),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: busy || !_phoneOk ? null : _pay,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(50),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          icon: busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.lock_rounded, size: 18),
          label: Text('${tr('Pay')} ${rwf(widget.amount)}'),
        ),
      ],
    );
  }
}

class _NetworkCard extends StatelessWidget {
  const _NetworkCard({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? color.withValues(alpha: 0.14) : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? color : AppColors.grey.withValues(alpha: 0.35),
          width: selected ? 2 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            CircleAvatar(radius: 6, backgroundColor: color),
            const SizedBox(width: 8),
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({
    required this.icon,
    required this.color,
    required this.title,
    required this.text,
    required this.button,
    required this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String text;
  final String button;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      const SizedBox(height: 8),
      Stack(alignment: Alignment.center, children: [
        if (busy)
          SizedBox(
            width: 84,
            height: 84,
            child: CircularProgressIndicator(strokeWidth: 3, color: color),
          ),
        CircleAvatar(
          radius: 34,
          backgroundColor: color.withValues(alpha: 0.14),
          child: Icon(icon, color: color, size: 36),
        ),
      ]),
      const SizedBox(height: 14),
      Text(title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
      const SizedBox(height: 6),
      Text(text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.grey, height: 1.4)),
      const SizedBox(height: 18),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: onTap,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: Text(button),
        ),
      ),
    ]);
  }
}
