import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:businessfinder/core/i18n/tr.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/colors.dart';
import '../data/payment_methods.dart';
import '../data/shop_models.dart';
import '../data/shop_repository.dart';

/// Makes the order on the server, then walks the buyer through paying.
/// Returns true when the buyer finished (paid or cancelled).
Future<bool> showCheckout(
  BuildContext context, {
  required String businessId,
  required Map<String, int> qtyByProductId,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final ({String orderId, int total}) created;
  try {
    created = await ShopRepository().createOrder(
      businessId: businessId,
      qtyByProductId: qtyByProductId,
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    return false;
  }
  if (!context.mounted) return false;
  final done = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    showDragHandle: true,
    builder: (_) => PaySheet(orderId: created.orderId),
  );
  return done ?? false;
}

/// Pay one order. Also opened from the Orders page to pay or retry later.
class PaySheet extends StatefulWidget {
  const PaySheet({super.key, required this.orderId});
  final String orderId;

  @override
  State<PaySheet> createState() => _PaySheetState();
}

class _PaySheetState extends State<PaySheet> with WidgetsBindingObserver {
  final _repo = ShopRepository();
  final _txRef = TextEditingController();
  final PaymentMethod _method = PaymentMethods.current;
  bool _dialed = false;
  bool _askResult = false;
  bool _busy = false;
  final bool _isDesktop = !(Platform.isAndroid || Platform.isIOS);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _txRef.dispose();
    super.dispose();
  }

  // Back from the MoMo pop-up: ask how it went.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _dialed && !_askResult) {
      setState(() => _askResult = true);
    }
  }

  Future<void> _pay(ShopOrder o) async {
    final ok = await _method.start(merchantCode: o.momoCode, amount: o.total);
    if (!mounted) return;
    if (ok) {
      setState(() => _dialed = true);
    } else {
      setState(() => _askResult = true); // e.g. on a computer: dial by hand
    }
  }

  Future<void> _answer(Future<void> Function() action) async {
    setState(() => _busy = true);
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      nav.pop(true);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Not saved: $e')));
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ShopOrder?>(
      stream: _repo.order(widget.orderId),
      builder: (context, snap) {
        final o = snap.data;
        if (o == null) {
          return const SizedBox(
              height: 200, child: Center(child: CircularProgressIndicator()));
        }
        final ussd = MomoUssdPayment.ussdFor(o.momoCode, o.total);
        return Padding(
          padding: EdgeInsets.fromLTRB(
              20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Pay ${o.businessName}',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(o.summary, style: const TextStyle(color: AppColors.grey)),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.mist,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(children: [
                    Text(formatRwf(o.total),
                        style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            color: AppColors.primaryDark)),
                    const SizedBox(height: 6),
                    Text('MoMo Pay code ${o.momoCode}'
                        '${o.momoName != null ? ' · ${o.momoName}' : ''}'),
                    const SizedBox(height: 4),
                    GestureDetector(
                      onTap: () => Clipboard.setData(ClipboardData(text: ussd)),
                      child: Text('$ussd  (tap to copy)',
                          style: const TextStyle(
                              color: AppColors.grey, fontSize: 12)),
                    ),
                  ]),
                ),
                const SizedBox(height: 12),
                if (o.momoName != null)
                  Text(
                    'MTN will show the name "${o.momoName}" before you enter your PIN. '
                    'If the name is different, cancel.',
                    style: const TextStyle(fontSize: 12, color: AppColors.grey),
                  ),
                const SizedBox(height: 16),
                if (!_askResult && _isDesktop) ...[
                  // A computer cannot dial USSD: pay from your MTN phone.
                  Text(tr('Pay from your phone'),
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: 8),
                  Text('1. ${tr('On your MTN phone, dial:')}'),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.primary),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(children: [
                      Expanded(
                        child: SelectableText(ussd,
                            style: const TextStyle(
                                fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: 1)),
                      ),
                      IconButton(
                        tooltip: tr('Copy'),
                        icon: const Icon(Icons.copy_rounded),
                        onPressed: () => Clipboard.setData(ClipboardData(text: ussd)),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 8),
                  Text('2. ${tr('Check the name MTN shows, then enter your MoMo PIN.')}'),
                  Text('3. ${tr('Come back here when MTN confirms.')}'),
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 50,
                    child: FilledButton.icon(
                      onPressed: () => setState(() => _askResult = true),
                      icon: const Icon(Icons.check_rounded),
                      label: Text(tr('I have dialled it')),
                    ),
                  ),
                  TextButton(
                    onPressed: _busy ? null : () => _answer(() => _repo.buyerCancelled(o.id)),
                    child: Text(tr('Cancel order')),
                  ),
                ] else if (!_askResult) ...[
                  SizedBox(
                    height: 52,
                    child: FilledButton.icon(
                      onPressed: () => _pay(o),
                      icon: const Icon(Icons.phone_in_talk_rounded),
                      label: Text(_dialed
                          ? 'Open MoMo again'
                          : 'Pay with ${_method.label}'),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    tr('Your phone dialer opens with the code ready. Press call, then enter your MoMo PIN.'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, color: AppColors.grey),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _answer(() => _repo.buyerCancelled(o.id)),
                    child: Text(tr('Cancel order')),
                  ),
                ] else ...[
                  Text(tr('Did the payment go through?'),
                      textAlign: TextAlign.center,
                      style:
                          const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _txRef,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: tr('Transaction ID from the MoMo SMS (optional)'),
                      helperText: tr('Helps the shop find your payment quickly.'),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 50,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                          backgroundColor: AppColors.success),
                      onPressed: _busy
                          ? null
                          : () => _answer(
                              () => _repo.buyerPaid(o.id, txRef: _txRef.text)),
                      icon: const Icon(Icons.check_circle_rounded),
                      label: Text(tr('Yes, I paid')),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _busy ? null : () => _pay(o),
                        child: Text(tr('Try again')),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.error),
                        onPressed: _busy
                            ? null
                            : () => _answer(() => _repo.buyerCancelled(o.id)),
                        child: Text(tr('No, cancel')),
                      ),
                    ),
                  ]),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
