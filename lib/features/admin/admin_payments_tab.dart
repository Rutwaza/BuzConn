import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/theme/colors.dart';
import '../billing/billing_service.dart';
import 'package:businessfinder/core/widgets/app_toast.dart';

/// Admin panel -> Payments (admin only).
///  - Prices: extra page, boost packages, free pages per person.
///  - Gateway (IremboPay) settings and the "Payments ready" switch.
///  - Give an extra page or a boost for free.
///  - Every payment, with "Mark paid" for ones checked by hand.
class AdminPaymentsTab extends StatefulWidget {
  const AdminPaymentsTab({super.key});

  @override
  State<AdminPaymentsTab> createState() => _AdminPaymentsTabState();
}

class _AdminPaymentsTabState extends State<AdminPaymentsTab> {
  final _svc = BillingService.instance;
  Map<String, dynamic>? _cfg;
  bool _gatewayReady = false;
  bool _secretSet = false;
  bool _saving = false;
  String _filter = 'all';

  final _pagePrice = TextEditingController();
  final _secondPrice = TextEditingController();
  final _freePages = TextEditingController();
  final _accountId = TextEditingController();
  final _codePage = TextEditingController();
  final _codeBoost = TextEditingController();
  final _boostDays = <TextEditingController>[];
  final _boostPrice = <TextEditingController>[];
  bool _ready = false;
  String _env = 'sandbox';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_pagePrice, _secondPrice, _freePages, _accountId, _codePage, _codeBoost, ..._boostDays, ..._boostPrice]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await _svc.admin({'action': 'get'});
      final c = Map<String, dynamic>.from(r['config'] as Map);
      final ir = Map<String, dynamic>.from(c['irembopay'] as Map? ?? {});
      final codes = Map<String, dynamic>.from(ir['productCodes'] as Map? ?? {});
      _pagePrice.text = '${c['pageSlotPrice'] ?? ''}';
      _secondPrice.text = c['secondPagePrice'] == null ? '' : '${c['secondPagePrice']}';
      _freePages.text = '${c['freePages'] ?? 1}';
      _accountId.text = (ir['accountId'] ?? '').toString();
      _codePage.text = (codes['page_slot'] ?? '').toString();
      _codeBoost.text = (codes['boost'] ?? '').toString();
      _boostDays.clear();
      _boostPrice.clear();
      for (final p in (c['boostPackages'] as List? ?? [])) {
        final m = Map<String, dynamic>.from(p as Map);
        _boostDays.add(TextEditingController(text: '${m['days']}'));
        _boostPrice.add(TextEditingController(text: '${m['price']}'));
      }
      setState(() {
        _cfg = c;
        _ready = c['ready'] == true;
        _env = ir['env'] == 'live' ? 'live' : 'sandbox';
        _gatewayReady = r['gatewayReady'] == true;
        _secretSet = r['secretSet'] == true;
      });
    } catch (e) {
      if (mounted) {
        showToast(context, 'Could not load: $e');
      }
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await _svc.admin({
        'action': 'config',
        'config': {
          'ready': _ready,
          'pageSlotPrice': int.tryParse(_pagePrice.text.trim()) ?? 0,
          // Empty = the 2nd page costs the same as the others.
          'secondPagePrice': _secondPrice.text.trim().isEmpty
              ? null
              : (int.tryParse(_secondPrice.text.trim()) ?? 0),
          'freePages': int.tryParse(_freePages.text.trim()) ?? 1,
          'boostPackages': [
            for (var i = 0; i < _boostDays.length; i++)
              {
                'id': 'boost_${int.tryParse(_boostDays[i].text) ?? i}d',
                'days': int.tryParse(_boostDays[i].text) ?? 1,
                'price': int.tryParse(_boostPrice[i].text) ?? 0,
              }
          ],
          'irembopay': {
            'env': _env,
            'accountId': _accountId.text.trim(),
            'productCodes': {'page_slot': _codePage.text.trim(), 'boost': _codeBoost.text.trim()},
          },
        },
      });
      setState(() {
        _gatewayReady = r['gatewayReady'] == true;
        _secretSet = r['secretSet'] == true;
      });
      messenger.showSnackBar(const SnackBar(content: Text('Saved')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _give() async {
    final user = TextEditingController();
    final post = TextEditingController();
    var item = 'page_slot';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Give for free'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'page_slot', label: Text('Extra page')),
                ButtonSegment(value: 'boost', label: Text('Boost a post')),
              ],
              selected: {item},
              onSelectionChanged: (s) => set(() => item = s.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: user,
              decoration: const InputDecoration(labelText: 'Username', prefixText: '@'),
            ),
            if (item == 'boost')
              TextField(
                controller: post,
                decoration: const InputDecoration(
                    labelText: 'Post id', helperText: 'From the post link: /p/<id>'),
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Give')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final name = user.text.trim().replaceFirst('@', '').toLowerCase();
      final u = await FirebaseFirestore.instance.collection('usernames').doc(name).get();
      final uid = u.data()?['uid']?.toString();
      if (uid == null) throw 'No user @$name';
      await _svc.admin({
        'action': 'give',
        'uid': uid,
        'item': item,
        if (item == 'boost') 'postId': post.text.trim(),
      });
      messenger.showSnackBar(const SnackBar(content: Text('Given ✓')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _markPaid(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Mark as paid?'),
        content: const Text(
            'Only if you checked the money arrived (e.g. MoMo message). The person gets the item right away.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Mark paid')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _svc.admin({'action': 'markPaid', 'paymentId': id});
      messenger.showSnackBar(const SnackBar(content: Text('Done ✓')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cfg == null) return const Center(child: CircularProgressIndicator());
    return ListView(padding: const EdgeInsets.all(16), children: [
      _gatewayCard(),
      const SizedBox(height: 12),
      _pricesCard(),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save_rounded),
            label: const Text('Save settings'),
          ),
        ),
        const SizedBox(width: 10),
        OutlinedButton.icon(
          onPressed: _give,
          icon: const Icon(Icons.card_giftcard_rounded),
          label: const Text('Give for free'),
        ),
      ]),
      const SizedBox(height: 20),
      _paymentsList(),
    ]);
  }

  Widget _gatewayCard() {
    final ok = _gatewayReady;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(ok ? Icons.check_circle_rounded : Icons.pending_rounded,
                color: ok ? AppColors.success : AppColors.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Text(ok ? 'IremboPay is live: people can pay' : 'Payments not live yet',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            ok
                ? 'Extra pages and boosts are paid through IremboPay.'
                : 'People see "Payments are coming soon". Their tries are listed below as "Waiting" so you see the demand. '
                    'To go live: set the secret IREMBOPAY_SECRET_KEY, add it in functions/billing.js, fill the account and product codes, then switch on.',
            style: const TextStyle(color: AppColors.grey, fontSize: 13),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 6, children: [
            _Pill('Secret key', _secretSet),
            _Pill('Account id', _accountId.text.trim().isNotEmpty),
            _Pill('Product codes', _codePage.text.trim().isNotEmpty && _codeBoost.text.trim().isNotEmpty),
            _Pill('Switched on', _ready),
          ]),
          const Divider(height: 28),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _ready,
            onChanged: (v) => setState(() => _ready = v),
            title: const Text('Payments ready'),
            subtitle: const Text('Works only when the key, account and codes are set too.'),
          ),
          Row(children: [
            const Text('Mode: '),
            const SizedBox(width: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'sandbox', label: Text('Sandbox (test)')),
                ButtonSegment(value: 'live', label: Text('Live')),
              ],
              selected: {_env},
              onSelectionChanged: (s) => setState(() => _env = s.first),
            ),
          ]),
          const SizedBox(height: 10),
          TextField(
            controller: _accountId,
            decoration: const InputDecoration(labelText: 'IremboPay payment account id'),
          ),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _codePage,
                decoration: const InputDecoration(labelText: 'Product code: extra page'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _codeBoost,
                decoration: const InputDecoration(labelText: 'Product code: boost'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _pricesCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Prices (RWF)', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _secondPrice,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '2nd page (paid once)',
                  helperText: 'Empty = same as the next ones',
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _pagePrice,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '3rd page and more (each)',
                  helperText: 'Paid once per page',
                ),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _freePages,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Free pages per person'),
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(child: SizedBox()),
          ]),
          const SizedBox(height: 14),
          const Text('Boost packages', style: TextStyle(fontWeight: FontWeight.w700)),
          for (var i = 0; i < _boostDays.length; i++)
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _boostDays[i],
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Days'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _boostPrice[i],
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Price'),
                ),
              ),
              IconButton(
                tooltip: 'Remove',
                onPressed: _boostDays.length <= 1
                    ? null
                    : () => setState(() {
                          _boostDays.removeAt(i).dispose();
                          _boostPrice.removeAt(i).dispose();
                        }),
                icon: const Icon(Icons.remove_circle_outline_rounded),
              ),
            ]),
          if (_boostDays.length < 6)
            TextButton.icon(
              onPressed: () => setState(() {
                _boostDays.add(TextEditingController(text: '30'));
                _boostPrice.add(TextEditingController(text: '12000'));
              }),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add package'),
            ),
        ]),
      ),
    );
  }

  Widget _paymentsList() {
    Query<Map<String, dynamic>> q = FirebaseFirestore.instance.collection('payments');
    if (_filter != 'all') q = q.where('status', isEqualTo: _filter);
    q = q.orderBy('createdAt', descending: true).limit(80);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('Payments', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        const Spacer(),
        DropdownButton<String>(
          value: _filter,
          onChanged: (v) => setState(() => _filter = v ?? 'all'),
          items: const [
            DropdownMenuItem(value: 'all', child: Text('All')),
            DropdownMenuItem(value: 'not_ready', child: Text('Waiting (not live)')),
            DropdownMenuItem(value: 'pending', child: Text('Pending')),
            DropdownMenuItem(value: 'paid', child: Text('Paid')),
            DropdownMenuItem(value: 'failed', child: Text('Failed')),
          ],
        ),
      ]),
      StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: q.snapshots(),
        builder: (context, snap) {
          if (snap.hasError) return Text('${snap.error}');
          if (!snap.hasData) return const LinearProgressIndicator();
          final docs = snap.data!.docs;
          if (docs.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No payments yet.', style: TextStyle(color: AppColors.grey)),
            );
          }
          final paid = docs.where((d) => d.data()['status'] == 'paid').fold<num>(
              0, (n, d) => n + ((d.data()['amount'] as num?) ?? 0));
          return Column(children: [
            if (_filter == 'all' || _filter == 'paid')
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text('Paid in this list: ${rwf(paid)}',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            for (final d in docs) _PaymentRow(id: d.id, p: d.data(), onMarkPaid: _markPaid),
          ]);
        },
      ),
    ]);
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.label, this.ok);
  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final c = ok ? AppColors.success : AppColors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(99)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(ok ? Icons.check_rounded : Icons.close_rounded, size: 14, color: c),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 12, color: c, fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

class _PaymentRow extends StatelessWidget {
  const _PaymentRow({required this.id, required this.p, required this.onMarkPaid});
  final String id;
  final Map<String, dynamic> p;
  final void Function(String id) onMarkPaid;

  @override
  Widget build(BuildContext context) {
    final status = (p['status'] ?? '').toString();
    final color = switch (status) {
      'paid' => AppColors.success,
      'failed' => AppColors.error,
      'not_ready' => AppColors.warning,
      _ => AppColors.primary,
    };
    final label = switch (status) {
      'not_ready' => 'Waiting',
      'paid' => p['provider'] == 'gift' ? 'Gift' : 'Paid',
      _ => status,
    };
    final at = (p['createdAt'] as Timestamp?)?.toDate();
    final what = p['item'] == 'page_slot' ? 'Extra page' : 'Boost ${p['days'] ?? ''} days';
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        leading: Icon(p['item'] == 'page_slot' ? Icons.add_business_rounded : Icons.rocket_launch_rounded),
        title: Text('$what · ${rwf((p['amount'] as num?) ?? 0)}'),
        subtitle: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          future: FirebaseFirestore.instance.collection('users').doc((p['uid'] ?? '').toString()).get(),
          builder: (_, s) {
            final u = s.data?.data() ?? {};
            final who = u['username'] != null ? '@${u['username']}' : (u['name'] ?? p['uid'] ?? '').toString();
            return Text('$who${at == null ? '' : ' · ${at.day}/${at.month}/${at.year}'}');
          },
        ),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(99)),
            child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12)),
          ),
          if (status == 'not_ready' || status == 'pending')
            IconButton(
              tooltip: 'Mark paid',
              onPressed: () => onMarkPaid(id),
              icon: const Icon(Icons.done_all_rounded),
            ),
        ]),
      ),
    );
  }
}
