import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/colors.dart';
import '../../core/widgets/verified_badge.dart';
import '../shop/data/shop_models.dart';
import '../shop/ui/orders_page.dart' show OrderTracker;
import 'admin_service.dart';
import 'admin_payments_tab.dart';

/// The Admin panel (Duhuze team only): Dashboard, Reports, Users, Pages,
/// Verification, Orders, Activity, Team. Every action is checked again on
/// the server (functions/admin.js) and logged in `admin_events`.
/// Guide: README -> "Admin panel".
class AdminPanelPage extends StatefulWidget {
  const AdminPanelPage({super.key});

  @override
  State<AdminPanelPage> createState() => _AdminPanelPageState();
}

class _Section {
  const _Section(this.icon, this.label, this.adminOnly);
  final IconData icon;
  final String label;
  final bool adminOnly;
}

const _sections = [
  _Section(Icons.space_dashboard_rounded, 'Dashboard', false),
  _Section(Icons.flag_rounded, 'Reports', false),
  _Section(Icons.people_alt_rounded, 'Users', false),
  _Section(Icons.storefront_rounded, 'Pages', false),
  _Section(Icons.verified_rounded, 'Verification', true),
  _Section(Icons.receipt_long_rounded, 'Orders', false),
  _Section(Icons.history_rounded, 'Activity', true),
  _Section(Icons.shield_rounded, 'Team', true),
  _Section(Icons.payments_rounded, 'Payments', true),
];

class _AdminPanelPageState extends State<AdminPanelPage> {
  StaffRole? _role;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    AdminService.instance.role(refresh: true).then((r) {
      if (mounted) setState(() => _role = r);
    });
  }

  @override
  Widget build(BuildContext context) {
    final role = _role;
    if (role == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (role == StaffRole.none) {
      return Scaffold(
        appBar: AppBar(title: const Text('Admin panel')),
        body: const Center(child: Text('This area is only for the Duhuze team.')),
      );
    }
    final isAdmin = role == StaffRole.admin;
    final sections = [
      for (var i = 0; i < _sections.length; i++)
        if (!_sections[i].adminOnly || isAdmin) i,
    ];
    if (!sections.contains(_index)) _index = 0;
    void go(int i) => setState(() => _index = i);

    final body = switch (_index) {
      0 => _DashboardTab(isAdmin: isAdmin, onOpen: go),
      1 => const _Padded(_ReportsTab()),
      2 => _Padded(_UsersTab(isAdmin: isAdmin)),
      3 => _Padded(_PagesTab(isAdmin: isAdmin)),
      4 => const _Padded(_VerificationTab()),
      5 => const _Padded(_OrdersTab()),
      6 => const _Padded(_ActivityTab()),
      7 => const _Padded(_TeamTab()),
      _ => const _Padded(AdminPaymentsTab()),
    };
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final title = Text(
        '${isAdmin ? 'Admin' : 'Moderator'} · ${_sections[_index].label}');

    if (wide) {
      return Scaffold(
        appBar: AppBar(title: title),
        body: Row(children: [
          NavigationRail(
            extended: MediaQuery.sizeOf(context).width >= 1200,
            selectedIndex: sections.indexOf(_index),
            onDestinationSelected: (i) => go(sections[i]),
            labelType: MediaQuery.sizeOf(context).width >= 1200
                ? NavigationRailLabelType.none
                : NavigationRailLabelType.all,
            destinations: [
              for (final i in sections)
                NavigationRailDestination(
                  icon: Icon(_sections[i].icon),
                  label: Text(_sections[i].label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: body),
        ]),
      );
    }
    return Scaffold(
      appBar: AppBar(title: title),
      drawer: NavigationDrawer(
        selectedIndex: sections.indexOf(_index),
        onDestinationSelected: (i) {
          Navigator.pop(context);
          go(sections[i]);
        },
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 20, 16, 12),
            child: Text(isAdmin ? 'Duhuze Admin' : 'Duhuze Moderator',
                style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final i in sections)
            NavigationDrawerDestination(
              icon: Icon(_sections[i].icon),
              label: Text(_sections[i].label),
            ),
        ],
      ),
      body: body,
    );
  }
}

class _Padded extends StatelessWidget {
  const _Padded(this.child);
  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: child,
        ),
      );
}

// ----------------------------------------------------------------- helpers --

Future<void> _run(BuildContext context, Future<void> Function() action, String done) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await action();
    messenger.showSnackBar(SnackBar(content: Text(done)));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
  }
}

Future<bool> _confirm(BuildContext context, String title, String text) async {
  return await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Yes, do it')),
          ],
        ),
      ) ==
      true;
}

const _reasonLabels = {
  'spam': 'Spam',
  'sexual': 'Sexual content',
  'child_safety': 'CHILD SAFETY',
  'hate': 'Hate / harassment',
  'violence': 'Violence / threats',
  'scam': 'Scam / fake shop',
  'fake': 'Fake account',
  'other': 'Other',
};

String _when(Timestamp? t) =>
    t == null ? '' : DateFormat('d MMM, HH:mm').format(t.toDate());

// ----------------------------------------------------------------- reports --

class _ReportsTab extends StatefulWidget {
  const _ReportsTab();

  @override
  State<_ReportsTab> createState() => _ReportsTabState();
}

class _ReportsTabState extends State<_ReportsTab> {
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Open'), icon: Icon(Icons.inbox_rounded)),
              ButtonSegment(value: false, label: Text('Handled'), icon: Icon(Icons.done_all_rounded)),
            ],
            selected: {_open},
            onSelectionChanged: (v) => setState(() => _open = v.first),
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: AdminService.instance.reports(open: _open),
            builder: (context, snap) {
              if (snap.hasError) return Center(child: Text('Could not load: ${snap.error}'));
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              final docs = [...snap.data!.docs]
                // Child safety first.
                ..sort((a, b) {
                  final ua = a.data()['reason'] == 'child_safety' ? 0 : 1;
                  final ub = b.data()['reason'] == 'child_safety' ? 0 : 1;
                  return ua.compareTo(ub);
                });
              if (docs.isEmpty) {
                return Center(child: Text(_open ? 'No open reports. 🎉' : 'Nothing handled yet.'));
              }
              return ListView.builder(
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: docs.length,
                itemBuilder: (_, i) => _ReportTile(
                  doc: docs[i],
                  onChanged: () => setState(() {}),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ReportTile extends StatelessWidget {
  const _ReportTile({required this.doc, required this.onChanged});
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final r = doc.data();
    final urgent = r['reason'] == 'child_safety';
    final status = (r['status'] ?? 'open').toString();
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: urgent ? const BorderSide(color: AppColors.error, width: 2) : BorderSide.none,
      ),
      child: ListTile(
        leading: Icon(urgent ? Icons.warning_amber_rounded : Icons.flag_outlined,
            color: urgent ? AppColors.error : AppColors.primary),
        title: Text('${_reasonLabels[r['reason']] ?? r['reason']} · ${r['targetType']}',
            style: TextStyle(fontWeight: FontWeight.w700, color: urgent ? AppColors.error : null)),
        subtitle: Text([
          if ((r['preview'] ?? '').toString().isNotEmpty) '“${r['preview']}”',
          if ((r['details'] ?? '').toString().isNotEmpty) 'Note: ${r['details']}',
          status == 'open' ? _when(r['createdAt'] as Timestamp?) : '$status by ${r['handledBy']} · ${r['action']}',
        ].join('\n'), maxLines: 4, overflow: TextOverflow.ellipsis),
        isThreeLine: true,
        onTap: () async {
          await showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            showDragHandle: true,
            builder: (_) => _ReportSheet(reportId: doc.id, report: r),
          );
          onChanged();
        },
      ),
    );
  }
}

class _ReportSheet extends StatefulWidget {
  const _ReportSheet({required this.reportId, required this.report});
  final String reportId;
  final Map<String, dynamic> report;

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  final _note = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>?> _load(String collection, String? id) async {
    if (id == null || id.isEmpty) return null;
    final d = await FirebaseFirestore.instance.collection(collection).doc(id).get();
    return d.data();
  }

  Future<void> _act(String action, String confirmText) async {
    if (action != 'dismiss' && !await _confirm(context, 'Are you sure?', confirmText)) return;
    if (!mounted) return;
    setState(() => _busy = true);
    final nav = Navigator.of(context);
    await _run(context, () => AdminService.instance.resolveReport(widget.reportId, action, note: _note.text),
        'Report handled');
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.report;
    final type = (r['targetType'] ?? '').toString();
    final targetId = r['targetId']?.toString();
    final ownerId = r['targetOwnerId']?.toString();
    final canRemove = type == 'post' || type == 'status';
    final open = (r['status'] ?? 'open') == 'open';

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('${_reasonLabels[r['reason']] ?? r['reason']} · $type',
                style: Theme.of(context).textTheme.titleLarge),
            Text('Reported ${_when(r['createdAt'] as Timestamp?)}',
                style: const TextStyle(color: AppColors.grey)),
            if ((r['details'] ?? '').toString().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Reporter wrote: ${r['details']}'),
              ),
            const SizedBox(height: 14),
            // The reported person.
            FutureBuilder<Map<String, dynamic>?>(
              future: _load('users', ownerId),
              builder: (context, snap) {
                final u = snap.data;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundImage: (u?['imageUrl'] as String?)?.startsWith('http') == true
                        ? CachedNetworkImageProvider(u!['imageUrl'] as String)
                        : null,
                  ),
                  title: Text((u?['name'] ?? u?['username'] ?? 'Unknown user').toString()),
                  subtitle: Text(u?['suspended'] == true ? 'SUSPENDED' : '@${u?['username'] ?? '-'}'),
                  trailing: ownerId == null
                      ? null
                      : TextButton(
                          onPressed: () => context.push(AppRoutes.clientProfilePath(ownerId)),
                          child: const Text('Profile'),
                        ),
                );
              },
            ),
            // The reported content.
            if (canRemove)
              FutureBuilder<Map<String, dynamic>?>(
                future: _load(type == 'post' ? 'posts' : 'statuses', targetId),
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const LinearProgressIndicator();
                  }
                  final d = snap.data;
                  if (d == null) return const Text('The content no longer exists (already deleted).');
                  final media = d['media'] is List && (d['media'] as List).isNotEmpty
                      ? ((d['media'] as List).first as Map)['url']?.toString()
                      : (d['imageUrl'] ?? d['mediaUrl'])?.toString();
                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.mist,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if (media != null && media.startsWith('http') && !media.contains('.mp4'))
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: CachedNetworkImage(imageUrl: media, height: 220, fit: BoxFit.cover),
                        ),
                      if (media != null && media.contains('.mp4')) const Text('🎬 Video (open the profile to watch)'),
                      const SizedBox(height: 6),
                      Text((d['content'] ?? d['text'] ?? '').toString(),
                          style: const TextStyle(color: AppColors.primaryDark)),
                    ]),
                  );
                },
              ),
            if (type == 'chat')
              const Text(
                'Chats are private, so they are not shown here. If you need the messages '
                '(threats, abuse, fraud), the admin opens them from the PC: README → '
                '"Ghost message archive" / exportChatBetweenUsers. Only for this report.',
                style: TextStyle(color: AppColors.grey),
              ),
            if (r['reason'] == 'child_safety')
              Container(
                margin: const EdgeInsets.only(top: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'CHILD SAFETY: do not download or forward anything. Remove + suspend now, '
                  'keep the evidence, and report to RIB. Steps: docs/MODERATION.md.',
                  style: TextStyle(color: AppColors.error, fontWeight: FontWeight.w600),
                ),
              ),
            const SizedBox(height: 14),
            if (open) ...[
              TextField(
                controller: _note,
                maxLength: 500,
                decoration: const InputDecoration(labelText: 'Note (why you decided this)'),
              ),
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _act('dismiss', ''),
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('Dismiss (no problem)'),
                ),
                if (canRemove)
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : () => _act('remove', 'The $type will be deleted for everyone.'),
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: Text('Remove $type'),
                  ),
                if (ownerId != null)
                  FilledButton.tonalIcon(
                    onPressed: _busy
                        ? null
                        : () => _act('suspend', 'The person is logged out and cannot sign in until restored.'),
                    icon: const Icon(Icons.block_rounded),
                    label: const Text('Suspend user'),
                  ),
                if (canRemove && ownerId != null)
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: AppColors.error),
                    onPressed: _busy
                        ? null
                        : () => _act('remove_and_suspend', 'Delete the $type AND suspend the person.'),
                    icon: const Icon(Icons.gavel_rounded),
                    label: const Text('Remove + suspend'),
                  ),
              ]),
            ] else
              Text('Handled: ${r['action']} by ${r['handledBy']}${(r['adminNote'] ?? '').toString().isNotEmpty ? '\nNote: ${r['adminNote']}' : ''}'),
          ],
        ),
      ),
    );
  }
}

// --------------------------------------------------------------- dashboard --

class _DashboardTab extends StatefulWidget {
  const _DashboardTab({required this.isAdmin, required this.onOpen});
  final bool isAdmin;
  final ValueChanged<int> onOpen;

  @override
  State<_DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<_DashboardTab> {
  late Future<Map<String, dynamic>> _stats = AdminService.instance.stats();

  Future<void> _announce() async {
    final text = await _askText(context,
        title: 'Announcement to everyone',
        hint: 'e.g. New: shops and order tracking are live 🎉',
        max: 300,
        action: 'Send to all');
    if (text == null || text.trim().length < 5 || !mounted) return;
    if (!await _confirm(context, 'Send to everyone?',
        'Every active user gets this in their notifications.')) {
      return;
    }
    if (!mounted) return;
    await _run(context, () async {
      final r = await AdminService.instance.broadcast(text);
      _lastSent = (r['sent'] as num?)?.toInt() ?? 0;
    }, 'Sent');
  }

  int _lastSent = 0;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {
        setState(() => _stats = AdminService.instance.stats());
        await _stats;
      },
      child: FutureBuilder<Map<String, dynamic>>(
        future: _stats,
        builder: (context, snap) {
          if (snap.hasError) {
            return ListView(children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Could not load: ${snap.error}'),
              ),
            ]);
          }
          final s = snap.data;
          if (s == null) return const Center(child: CircularProgressIndicator());
          int n(String k) => (s[k] as num?)?.toInt() ?? 0;
          final cards = <Widget>[
            _StatCard('Users', n('users'), Icons.people_alt_rounded,
                sub: '+${n('newUsers7d')} this week', onTap: () => widget.onOpen(2)),
            _StatCard('Pages', n('pages'), Icons.storefront_rounded,
                onTap: () => widget.onOpen(3)),
            _StatCard('Posts', n('posts'), Icons.dynamic_feed_rounded,
                sub: '+${n('newPosts24h')} today'),
            _StatCard('Groups', n('groups'), Icons.groups_rounded),
            _StatCard('Open reports', n('openReports'), Icons.flag_rounded,
                color: n('openReports') > 0 ? AppColors.primary : null,
                onTap: () => widget.onOpen(1)),
            _StatCard('Verification requests', n('pendingVerifications'),
                Icons.verified_rounded,
                color: n('pendingVerifications') > 0 ? const Color(0xFF1D9BF0) : null,
                onTap: widget.isAdmin ? () => widget.onOpen(4) : null),
            _StatCard('Orders', n('orders'), Icons.receipt_long_rounded,
                sub: '${n('disputes')} not received',
                color: n('disputes') > 0 ? Colors.orange : null,
                onTap: () => widget.onOpen(5)),
            _StatCard('Suspended', n('suspended') + n('suspendedPages'),
                Icons.block_rounded,
                sub: '${n('suspended')} people · ${n('suspendedPages')} pages',
                onTap: () => widget.onOpen(2)),
            _StatCard('Verified', n('verifiedUsers') + n('verifiedPages'),
                Icons.verified_user_rounded,
                sub: '${n('verifiedUsers')} people · ${n('verifiedPages')} pages'),
          ];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (n('urgentReports') > 0)
                Card(
                  color: AppColors.error.withValues(alpha: 0.12),
                  child: ListTile(
                    leading: const Icon(Icons.warning_amber_rounded,
                        color: AppColors.error),
                    title: Text(
                        '${n('urgentReports')} CHILD SAFETY report(s) waiting',
                        style: const TextStyle(
                            color: AppColors.error, fontWeight: FontWeight.w800)),
                    subtitle: const Text('Handle these first. See docs/MODERATION.md.'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => widget.onOpen(1),
                  ),
                ),
              LayoutBuilder(builder: (context, c) {
                final cols = c.maxWidth >= 900 ? 3 : (c.maxWidth >= 560 ? 2 : 1);
                return GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: cols,
                  childAspectRatio: cols == 1 ? 3.4 : 2.3,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  children: cards,
                );
              }),
              const SizedBox(height: 18),
              Text('Quick actions', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (widget.isAdmin)
                  FilledButton.icon(
                    onPressed: _announce,
                    icon: const Icon(Icons.campaign_rounded),
                    label: const Text('Send announcement'),
                  ),
                OutlinedButton.icon(
                  onPressed: () => widget.onOpen(1),
                  icon: const Icon(Icons.flag_outlined),
                  label: const Text('Review reports'),
                ),
                OutlinedButton.icon(
                  onPressed: () => setState(() => _stats = AdminService.instance.stats()),
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Refresh'),
                ),
              ]),
              if (_lastSent > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('Last announcement reached $_lastSent people.',
                      style: const TextStyle(color: AppColors.grey)),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard(this.label, this.value, this.icon,
      {this.sub, this.color, this.onTap});
  final String label;
  final int value;
  final IconData icon;
  final String? sub;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: c.withValues(alpha: 0.12),
              child: Icon(icon, color: c),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(NumberFormat.decimalPattern().format(value),
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                  Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (sub != null)
                    Text(sub!, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.grey, fontSize: 12)),
                ],
              ),
            ),
            if (onTap != null) const Icon(Icons.chevron_right_rounded, color: AppColors.grey),
          ]),
        ),
      ),
    );
  }
}

Future<String?> _askText(BuildContext context,
    {required String title, String hint = '', int max = 500, String action = 'OK'}) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        maxLength: max,
        maxLines: 3,
        decoration: InputDecoration(hintText: hint),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(action)),
      ],
    ),
  );
}

Widget _tag(String text, Color color) => Container(
      margin: const EdgeInsets.only(right: 6, top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text,
          style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800)),
    );

// ------------------------------------------------------------------- users --

enum _UserFilter { recent, suspended, verified }

class _UsersTab extends StatefulWidget {
  const _UsersTab({required this.isAdmin});
  final bool isAdmin;

  @override
  State<_UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends State<_UsersTab> {
  final _search = TextEditingController();
  _UserFilter _filter = _UserFilter.recent;
  late Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _results = _load();
  bool _searching = false;

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _load() async {
    final users = FirebaseFirestore.instance.collection('users');
    if (_searching) return AdminService.instance.searchUsers(_search.text);
    switch (_filter) {
      case _UserFilter.suspended:
        return AdminService.instance.suspendedUsers();
      case _UserFilter.verified:
        return (await users.where('verified', isEqualTo: true).limit(100).get()).docs;
      case _UserFilter.recent:
        try {
          return (await users.orderBy('createdAt', descending: true).limit(60).get()).docs;
        } catch (_) {
          return (await users.limit(60).get()).docs;
        }
    }
  }

  void _reload() => setState(() => _results = _load());

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
        child: TextField(
          controller: _search,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) {
            _searching = _search.text.trim().length >= 2;
            _reload();
          },
          decoration: InputDecoration(
            hintText: 'Search a name or username (one word)',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _searching
                ? IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () {
                      _search.clear();
                      _searching = false;
                      _reload();
                    })
                : null,
            border: const OutlineInputBorder(),
          ),
        ),
      ),
      if (!_searching)
        SegmentedButton<_UserFilter>(
          segments: const [
            ButtonSegment(value: _UserFilter.recent, label: Text('Newest'), icon: Icon(Icons.schedule_rounded)),
            ButtonSegment(value: _UserFilter.suspended, label: Text('Suspended'), icon: Icon(Icons.block_rounded)),
            ButtonSegment(value: _UserFilter.verified, label: Text('Verified'), icon: Icon(Icons.verified_rounded)),
          ],
          selected: {_filter},
          onSelectionChanged: (v) {
            _filter = v.first;
            _reload();
          },
        ),
      const SizedBox(height: 6),
      Expanded(
        child: FutureBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
          future: _results,
          builder: (context, snap) {
            if (snap.hasError) return Center(child: Text('${snap.error}'));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final users = snap.data!;
            if (users.isEmpty) return const Center(child: Text('Nobody here.'));
            return ListView.separated(
              itemCount: users.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final u = users[i].data();
                final img = u['imageUrl'] as String?;
                return ListTile(
                  leading: CircleAvatar(
                    backgroundImage: img?.startsWith('http') == true
                        ? CachedNetworkImageProvider(img!)
                        : null,
                    child: img?.startsWith('http') == true ? null : const Icon(Icons.person),
                  ),
                  title: Row(children: [
                    Flexible(
                      child: Text((u['name'] ?? u['username'] ?? users[i].id).toString(),
                          overflow: TextOverflow.ellipsis),
                    ),
                    if (u['verified'] == true) ...[
                      const SizedBox(width: 4),
                      const VerifiedBadge(size: 14),
                    ],
                  ]),
                  subtitle: Wrap(children: [
                    Text('@${u['username'] ?? '-'}  '),
                    if (u['suspended'] == true) _tag('SUSPENDED', AppColors.error),
                  ]),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () async {
                    await showUserAdminSheet(context,
                        uid: users[i].id, isAdmin: widget.isAdmin);
                    _reload();
                  },
                );
              },
            );
          },
        ),
      ),
    ]);
  }
}

/// Everything about one person + every action on them.
Future<void> showUserAdminSheet(BuildContext context,
    {required String uid, required bool isAdmin}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (_) => _UserSheet(uid: uid, isAdmin: isAdmin),
  );
}

class _UserSheet extends StatefulWidget {
  const _UserSheet({required this.uid, required this.isAdmin});
  final String uid;
  final bool isAdmin;

  @override
  State<_UserSheet> createState() => _UserSheetState();
}

class _UserSheetState extends State<_UserSheet> {
  late Future<List<dynamic>> _data = _load();

  Future<List<dynamic>> _load() => Future.wait([
        FirebaseFirestore.instance.collection('users').doc(widget.uid).get(),
        AdminService.instance.userDetails(widget.uid),
      ]);

  void _reload() => setState(() => _data = _load());

  @override
  Widget build(BuildContext context) {
    final svc = AdminService.instance;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.82,
      child: FutureBuilder<List<dynamic>>(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final u = (snap.data![0] as DocumentSnapshot<Map<String, dynamic>>).data() ?? {};
          final d = snap.data![1] as Map<String, dynamic>;
          final auth = d['auth'] is Map ? Map<String, dynamic>.from(d['auth'] as Map) : null;
          final suspended = u['suspended'] == true;
          final verified = u['verified'] == true;
          final img = u['imageUrl'] as String?;
          final pages = (d['pages'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          Widget stat(String label, Object? v) => Column(children: [
                Text('${v ?? 0}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                Text(label, style: const TextStyle(color: AppColors.grey, fontSize: 12)),
              ]);
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              Row(children: [
                CircleAvatar(
                  radius: 32,
                  backgroundImage: img?.startsWith('http') == true ? CachedNetworkImageProvider(img!) : null,
                  child: img?.startsWith('http') == true ? null : const Icon(Icons.person, size: 32),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Flexible(
                        child: Text((u['name'] ?? 'User').toString(),
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                      ),
                      if (verified) ...[const SizedBox(width: 6), const VerifiedBadge()],
                    ]),
                    Text('@${u['username'] ?? '-'}', style: const TextStyle(color: AppColors.grey)),
                    Wrap(children: [
                      if (suspended) _tag('SUSPENDED', AppColors.error),
                      if (auth?['admin'] == true) _tag('ADMIN', AppColors.primary),
                      if (auth?['moderator'] == true) _tag('MODERATOR', AppColors.primary),
                      if (((d['reportsActioned'] as num?) ?? 0) > 0)
                        _tag('${d['reportsActioned']} strikes', Colors.orange),
                    ]),
                  ]),
                ),
              ]),
              const SizedBox(height: 14),
              Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                stat('Posts', d['posts']),
                stat('Followers', d['followers']),
                stat('Following', d['following']),
                stat('Reports', d['reportsAgainst']),
                stat('Orders', d['orders']),
              ]),
              const Divider(height: 28),
              if (auth != null) ...[
                _info(Icons.email_outlined, auth['email'] ?? 'no email',
                    trailing: auth['emailVerified'] == true ? 'verified' : 'not verified'),
                if (auth['phone'] != null) _info(Icons.phone_outlined, auth['phone']),
                _info(Icons.login_rounded, 'Signs in with ${(auth['providers'] as List?)?.join(', ') ?? '-'}'),
                _info(Icons.cake_outlined, 'Joined ${auth['createdAt'] ?? '-'}'),
                _info(Icons.access_time_rounded, 'Last sign-in ${auth['lastSignIn'] ?? '-'}'),
              ],
              if ((u['bio'] ?? '').toString().isNotEmpty) _info(Icons.notes_rounded, u['bio']),
              if (pages.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text('Pages', style: TextStyle(fontWeight: FontWeight.w800)),
                for (final p in pages)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.storefront_rounded),
                    title: Text(p['name'].toString()),
                    subtitle: Wrap(children: [
                      if (p['suspended'] == true) _tag('SUSPENDED', AppColors.error),
                      if (p['verified'] == true) _tag('VERIFIED', const Color(0xFF1D9BF0)),
                    ]),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => showPageAdminSheet(context,
                        businessId: p['id'].toString(), isAdmin: widget.isAdmin),
                  ),
              ],
              const SizedBox(height: 16),
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(
                  onPressed: () => context.push(AppRoutes.clientProfilePath(widget.uid)),
                  icon: const Icon(Icons.person_rounded),
                  label: const Text('Open profile'),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final msg = await _askText(context,
                        title: 'Message from the team',
                        hint: 'e.g. Please stop posting spam links.',
                        action: 'Send');
                    if (msg == null || msg.length < 3 || !context.mounted) return;
                    await _run(context, () => svc.warnUser(widget.uid, msg), 'Sent');
                  },
                  icon: const Icon(Icons.mark_email_unread_outlined),
                  label: const Text('Send warning'),
                ),
                if (widget.isAdmin)
                  OutlinedButton.icon(
                    onPressed: () async {
                      await _run(context, () => svc.setUserVerified(widget.uid, !verified),
                          verified ? 'Badge removed' : 'Verified ✓');
                      _reload();
                    },
                    icon: Icon(verified ? Icons.remove_moderator_outlined : Icons.verified_rounded),
                    label: Text(verified ? 'Remove ✓' : 'Verify ✓'),
                  ),
                if (suspended)
                  FilledButton.icon(
                    onPressed: () async {
                      await _run(context, () => svc.setSuspended(widget.uid, false), 'Restored');
                      _reload();
                    },
                    icon: const Icon(Icons.lock_open_rounded),
                    label: const Text('Restore account'),
                  )
                else
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: AppColors.error),
                    onPressed: () async {
                      final note = await _askText(context,
                          title: 'Suspend this account?',
                          hint: 'Reason (saved in the activity log)',
                          action: 'Suspend');
                      if (note == null || !context.mounted) return;
                      await _run(context, () => svc.setSuspended(widget.uid, true, note: note),
                          'Suspended');
                      _reload();
                    },
                    icon: const Icon(Icons.block_rounded),
                    label: const Text('Suspend'),
                  ),
              ]),
              const SizedBox(height: 8),
              const Text(
                'Suspend = logged out everywhere, can\'t sign in, posts hidden from feeds. Restore undoes it.',
                style: TextStyle(color: AppColors.grey, fontSize: 12),
              ),
            ],
          );
        },
      ),
    );
  }
}

Widget _info(IconData icon, Object? text, {String? trailing}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Icon(icon, size: 18, color: AppColors.grey),
        const SizedBox(width: 10),
        Expanded(child: Text('$text')),
        if (trailing != null) Text(trailing, style: const TextStyle(color: AppColors.grey, fontSize: 12)),
      ]),
    );

// ------------------------------------------------------------------- pages --

enum _PageFilter { recent, suspended, verified, shops }

class _PagesTab extends StatefulWidget {
  const _PagesTab({required this.isAdmin});
  final bool isAdmin;

  @override
  State<_PagesTab> createState() => _PagesTabState();
}

class _PagesTabState extends State<_PagesTab> {
  final _search = TextEditingController();
  _PageFilter _filter = _PageFilter.recent;
  late Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _results = _load();

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _load() async {
    final pages = FirebaseFirestore.instance.collection('businesses');
    final term = _search.text.trim().toLowerCase();
    if (term.length >= 2) {
      return (await pages.where('searchKeywords', arrayContains: term).limit(40).get()).docs;
    }
    switch (_filter) {
      case _PageFilter.suspended:
        return (await pages.where('suspended', isEqualTo: true).limit(100).get()).docs;
      case _PageFilter.verified:
        return (await pages.where('verified', isEqualTo: true).limit(100).get()).docs;
      case _PageFilter.shops:
        return (await pages.where('productCount', isGreaterThan: 0).limit(100).get()).docs;
      case _PageFilter.recent:
        try {
          return (await pages.orderBy('createdAt', descending: true).limit(60).get()).docs;
        } catch (_) {
          return (await pages.limit(60).get()).docs;
        }
    }
  }

  void _reload() => setState(() => _results = _load());

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
        child: TextField(
          controller: _search,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _reload(),
          decoration: const InputDecoration(
            hintText: 'Search a page name (one word)',
            prefixIcon: Icon(Icons.search_rounded),
            border: OutlineInputBorder(),
          ),
        ),
      ),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SegmentedButton<_PageFilter>(
          segments: const [
            ButtonSegment(value: _PageFilter.recent, label: Text('Newest')),
            ButtonSegment(value: _PageFilter.shops, label: Text('Shops')),
            ButtonSegment(value: _PageFilter.verified, label: Text('Verified')),
            ButtonSegment(value: _PageFilter.suspended, label: Text('Suspended')),
          ],
          selected: {_filter},
          onSelectionChanged: (v) {
            _filter = v.first;
            _search.clear();
            _reload();
          },
        ),
      ),
      const SizedBox(height: 6),
      Expanded(
        child: FutureBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
          future: _results,
          builder: (context, snap) {
            if (snap.hasError) return Center(child: Text('${snap.error}'));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final pages = snap.data!;
            if (pages.isEmpty) return const Center(child: Text('No pages here.'));
            return ListView.separated(
              itemCount: pages.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final p = pages[i].data();
                final img = (p['imageUrl'] ?? p['logoUrl']) as String?;
                return ListTile(
                  leading: CircleAvatar(
                    backgroundImage: img?.startsWith('http') == true ? CachedNetworkImageProvider(img!) : null,
                    child: img?.startsWith('http') == true ? null : const Icon(Icons.storefront_rounded),
                  ),
                  title: Row(children: [
                    Flexible(child: Text((p['name'] ?? 'Page').toString(), overflow: TextOverflow.ellipsis)),
                    if (p['verified'] == true) ...[const SizedBox(width: 4), const VerifiedBadge(size: 14)],
                  ]),
                  subtitle: Wrap(children: [
                    Text('${p['category'] ?? '-'}  '),
                    if (p['suspended'] == true) _tag('SUSPENDED', AppColors.error),
                    if (((p['productCount'] as num?) ?? 0) > 0) _tag('🛍 ${p['productCount']}', AppColors.success),
                  ]),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () async {
                    await showPageAdminSheet(context, businessId: pages[i].id, isAdmin: widget.isAdmin);
                    _reload();
                  },
                );
              },
            );
          },
        ),
      ),
    ]);
  }
}

Future<void> showPageAdminSheet(BuildContext context,
    {required String businessId, required bool isAdmin}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (_) => _PageSheet(businessId: businessId, isAdmin: isAdmin),
  );
}

class _PageSheet extends StatefulWidget {
  const _PageSheet({required this.businessId, required this.isAdmin});
  final String businessId;
  final bool isAdmin;

  @override
  State<_PageSheet> createState() => _PageSheetState();
}

class _PageSheetState extends State<_PageSheet> {
  late Future<List<dynamic>> _data = _load();

  Future<List<dynamic>> _load() async {
    final db = FirebaseFirestore.instance;
    final count = (Query<Map<String, dynamic>> q) async => (await q.count().get()).count ?? 0;
    return Future.wait([
      db.collection('businesses').doc(widget.businessId).get(),
      count(db.collection('page_follows').where('pageId', isEqualTo: widget.businessId)),
      count(db.collection('posts').where('businessId', isEqualTo: widget.businessId)),
      count(db.collection('orders').where('businessId', isEqualTo: widget.businessId)),
      count(db.collection('reports').where('targetId', isEqualTo: widget.businessId)),
    ]);
  }

  void _reload() => setState(() => _data = _load());

  @override
  Widget build(BuildContext context) {
    final svc = AdminService.instance;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: FutureBuilder<List<dynamic>>(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final p = (snap.data![0] as DocumentSnapshot<Map<String, dynamic>>).data() ?? {};
          final suspended = p['suspended'] == true;
          final verified = p['verified'] == true;
          final img = (p['imageUrl'] ?? p['logoUrl']) as String?;
          Widget stat(String label, Object? v) => Column(children: [
                Text('${v ?? 0}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                Text(label, style: const TextStyle(color: AppColors.grey, fontSize: 12)),
              ]);
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              Row(children: [
                CircleAvatar(
                  radius: 32,
                  backgroundImage: img?.startsWith('http') == true ? CachedNetworkImageProvider(img!) : null,
                  child: img?.startsWith('http') == true ? null : const Icon(Icons.storefront_rounded, size: 30),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Flexible(
                        child: Text((p['name'] ?? 'Page').toString(),
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                      ),
                      if (verified) ...[const SizedBox(width: 6), const VerifiedBadge()],
                    ]),
                    Text('${p['category'] ?? '-'} · ${p['location'] ?? p['address'] ?? ''}',
                        style: const TextStyle(color: AppColors.grey)),
                    Wrap(children: [
                      if (suspended) _tag('SUSPENDED', AppColors.error),
                      if ((p['momoCode'] ?? '').toString().isNotEmpty) _tag('MoMo ✓', AppColors.success),
                      if (((p['ratingCount'] as num?) ?? 0) > 0)
                        _tag('★ ${p['ratingAvg']} (${p['ratingCount']})', Colors.orange),
                    ]),
                  ]),
                ),
              ]),
              const SizedBox(height: 14),
              Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                stat('Followers', snap.data![1]),
                stat('Posts', snap.data![2]),
                stat('Products', p['productCount']),
                stat('Orders', snap.data![3]),
                stat('Reports', snap.data![4]),
              ]),
              const Divider(height: 28),
              if ((p['description'] ?? '').toString().isNotEmpty) _info(Icons.notes_rounded, p['description']),
              if ((p['phone'] ?? '').toString().isNotEmpty) _info(Icons.phone_outlined, p['phone']),
              if (suspended && (p['suspendedReason'] ?? '').toString().isNotEmpty)
                _info(Icons.gavel_rounded, 'Suspended: ${p['suspendedReason']}'),
              const SizedBox(height: 14),
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(
                  onPressed: () => context.push(AppRoutes.businessProfilePath(widget.businessId)),
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: const Text('Open page'),
                ),
                if ((p['ownerId'] ?? '').toString().isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: () => showUserAdminSheet(context,
                        uid: p['ownerId'].toString(), isAdmin: widget.isAdmin),
                    icon: const Icon(Icons.person_rounded),
                    label: const Text('Owner'),
                  ),
                if (widget.isAdmin)
                  OutlinedButton.icon(
                    onPressed: () async {
                      await _run(context, () => svc.setVerified(widget.businessId, !verified),
                          verified ? 'Badge removed' : 'Verified ✓');
                      _reload();
                    },
                    icon: Icon(verified ? Icons.remove_moderator_outlined : Icons.verified_rounded),
                    label: Text(verified ? 'Remove ✓' : 'Verify ✓'),
                  ),
                if (suspended)
                  FilledButton.icon(
                    onPressed: () async {
                      await _run(context, () => svc.setPageSuspended(widget.businessId, false), 'Page restored');
                      _reload();
                    },
                    icon: const Icon(Icons.play_circle_outline_rounded),
                    label: const Text('Restore page'),
                  )
                else
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: AppColors.error),
                    onPressed: () async {
                      final note = await _askText(context,
                          title: 'Suspend this page?',
                          hint: 'Reason (the owner sees it)',
                          action: 'Suspend page');
                      if (note == null || !context.mounted) return;
                      await _run(context,
                          () => svc.setPageSuspended(widget.businessId, true, note: note),
                          'Page suspended');
                      _reload();
                    },
                    icon: const Icon(Icons.pause_circle_outline_rounded),
                    label: const Text('Suspend page'),
                  ),
              ]),
              const SizedBox(height: 8),
              const Text(
                'A suspended page is hidden from feeds and search, its shop stops taking orders, '
                'and the owner can\'t edit it or post as it. The owner is notified.',
                style: TextStyle(color: AppColors.grey, fontSize: 12),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ------------------------------------------------------------ verification --

class _VerificationTab extends StatefulWidget {
  const _VerificationTab();

  @override
  State<_VerificationTab> createState() => _VerificationTabState();
}

class _VerificationTabState extends State<_VerificationTab> {
  bool _pending = true;

  @override
  Widget build(BuildContext context) {
    final col = FirebaseFirestore.instance.collection('verification_requests');
    final stream = (_pending
            ? col.where('status', isEqualTo: 'pending').orderBy('createdAt', descending: true)
            : col.where('status', whereIn: ['approved', 'rejected']).limit(60))
        .snapshots();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('Waiting'), icon: Icon(Icons.hourglass_top_rounded)),
            ButtonSegment(value: false, label: Text('Handled'), icon: Icon(Icons.done_all_rounded)),
          ],
          selected: {_pending},
          onSelectionChanged: (v) => setState(() => _pending = v.first),
        ),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          'Requests only arrive when every rule is met (account age, profile, posts, followers, '
          'clean record). Still check that the person or business is real before approving.',
          style: TextStyle(color: AppColors.grey, fontSize: 12),
        ),
      ),
      Expanded(
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: stream,
          builder: (context, snap) {
            if (snap.hasError) return Center(child: Text('Could not load: ${snap.error}'));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final docs = snap.data!.docs;
            if (docs.isEmpty) {
              return Center(child: Text(_pending ? 'No requests waiting. 🎉' : 'Nothing handled yet.'));
            }
            return ListView(
              padding: const EdgeInsets.all(12),
              children: [for (final d in docs) _VerificationCard(doc: d)],
            );
          },
        ),
      ),
    ]);
  }
}

class _VerificationCard extends StatelessWidget {
  const _VerificationCard({required this.doc});
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;

  @override
  Widget build(BuildContext context) {
    final r = doc.data();
    final isPage = r['kind'] == 'page';
    final checks = (r['checks'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map));
    final status = (r['status'] ?? '').toString();
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(isPage ? Icons.storefront_rounded : Icons.person_rounded, color: AppColors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text((r['targetName'] ?? '').toString(),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            ),
            _tag(isPage ? 'PAGE' : 'PERSON', AppColors.primary),
            if (status != 'pending')
              _tag(status.toUpperCase(), status == 'approved' ? AppColors.success : AppColors.error),
          ]),
          Text(_when(r['createdAt'] as Timestamp?), style: const TextStyle(color: AppColors.grey, fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final c in checks)
              Chip(
                visualDensity: VisualDensity.compact,
                avatar: Icon(c['ok'] == true ? Icons.check_circle_rounded : Icons.cancel_rounded,
                    size: 16, color: c['ok'] == true ? AppColors.success : AppColors.error),
                label: Text('${c['label']}${(c['detail'] ?? '').toString().isEmpty ? '' : ' (${c['detail']})'}',
                    style: const TextStyle(fontSize: 11.5)),
              ),
          ]),
          if ((r['note'] ?? '').toString().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('They wrote: ${r['note']}'),
            ),
          if ((r['reviewNote'] ?? '').toString().isNotEmpty)
            Text('Team note: ${r['reviewNote']}', style: const TextStyle(color: AppColors.grey)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              onPressed: () => isPage
                  ? context.push(AppRoutes.businessProfilePath(r['targetId'].toString()))
                  : context.push(AppRoutes.clientProfilePath(r['targetId'].toString())),
              icon: const Icon(Icons.open_in_new_rounded),
              label: const Text('Look at it'),
            ),
            if (status == 'pending') ...[
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: AppColors.error),
                onPressed: () async {
                  final note = await _askText(context,
                      title: 'Reject request',
                      hint: 'Tell them why (they see this)',
                      action: 'Reject');
                  if (note == null || !context.mounted) return;
                  await _run(context,
                      () => AdminService.instance.reviewVerification(doc.id, false, note: note), 'Rejected');
                },
                icon: const Icon(Icons.close_rounded),
                label: const Text('Reject'),
              ),
              FilledButton.icon(
                onPressed: () async {
                  if (!await _confirm(context, 'Approve?',
                      '${r['targetName']} gets the blue ✓ badge.')) {
                    return;
                  }
                  if (!context.mounted) return;
                  await _run(context, () => AdminService.instance.reviewVerification(doc.id, true),
                      'Verified ✓');
                },
                icon: const Icon(Icons.verified_rounded),
                label: const Text('Approve'),
              ),
            ],
          ]),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------------ orders --

class _OrdersTab extends StatefulWidget {
  const _OrdersTab();

  @override
  State<_OrdersTab> createState() => _OrdersTabState();
}

class _OrdersTabState extends State<_OrdersTab> {
  bool _disputes = true;

  @override
  Widget build(BuildContext context) {
    final col = FirebaseFirestore.instance.collection('orders');
    final query = _disputes
        ? col.where('status', isEqualTo: OrderStatus.notReceived.value).limit(100)
        : col.orderBy('createdAt', descending: true).limit(60);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('Not received'), icon: Icon(Icons.report_problem_outlined)),
            ButtonSegment(value: false, label: Text('Latest'), icon: Icon(Icons.receipt_long_rounded)),
          ],
          selected: {_disputes},
          onSelectionChanged: (v) => setState(() => _disputes = v.first),
        ),
      ),
      if (_disputes)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'The buyer says they paid, the shop says the money did not arrive. Compare the MoMo '
            'transaction ID with both sides; suspend the page or the buyer if someone is cheating.',
            style: TextStyle(color: AppColors.grey, fontSize: 12),
          ),
        ),
      Expanded(
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: query.snapshots(),
          builder: (context, snap) {
            if (snap.hasError) return Center(child: Text('Could not load: ${snap.error}'));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final orders = snap.data!.docs.map(ShopOrder.fromDoc).toList();
            if (orders.isEmpty) {
              return Center(child: Text(_disputes ? 'No problems. 🎉' : 'No orders yet.'));
            }
            return ListView(
              padding: const EdgeInsets.all(12),
              children: [
                for (final o in orders)
                  Card(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(
                            child: Text(o.businessName,
                                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                          ),
                          Text(formatRwf(o.total), style: const TextStyle(fontWeight: FontWeight.w800)),
                        ]),
                        Text('${o.summary} · ${_when(o.createdAt == null ? null : Timestamp.fromDate(o.createdAt!))}',
                            style: const TextStyle(color: AppColors.grey)),
                        if (o.txRef != null) Text('MoMo transaction ID: ${o.txRef}'),
                        const SizedBox(height: 8),
                        OrderTracker(status: o.status),
                        const SizedBox(height: 6),
                        Wrap(spacing: 8, children: [
                          TextButton.icon(
                            onPressed: () => showPageAdminSheet(context,
                                businessId: o.businessId, isAdmin: true),
                            icon: const Icon(Icons.storefront_rounded, size: 18),
                            label: const Text('Shop'),
                          ),
                          TextButton.icon(
                            onPressed: () => showUserAdminSheet(context, uid: o.buyerId, isAdmin: true),
                            icon: const Icon(Icons.person_rounded, size: 18),
                            label: const Text('Buyer'),
                          ),
                        ]),
                      ]),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    ]);
  }
}

// ---------------------------------------------------------------- activity --

const _eventLabels = {
  'user_suspended': '⛔ Suspended a person',
  'user_restored': '✅ Restored a person',
  'page_suspended': '⛔ Suspended a page',
  'page_restored': '✅ Restored a page',
  'user_verified': '✓ Verified a person',
  'user_unverified': 'Removed ✓ from a person',
  'verification_approved': '✓ Approved verification',
  'verification_rejected': 'Rejected verification',
  'user_warned': '✉️ Warned a person',
  'broadcast': '📢 Announcement',
  'moderator_added': '🛡 Added a moderator',
  'moderator_removed': 'Removed a moderator',
  'report_dismiss': 'Dismissed a report',
  'report_remove': '🗑 Removed reported content',
  'report_suspend': '⛔ Suspended from a report',
  'report_remove_and_suspend': '🔨 Removed + suspended',
};

class _ActivityTab extends StatelessWidget {
  const _ActivityTab();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('admin_events')
          .orderBy('at', descending: true)
          .limit(150)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('Could not load: ${snap.error}'));
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final docs = snap.data!.docs;
        if (docs.isEmpty) return const Center(child: Text('No actions yet.'));
        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final e = docs[i].data();
            final type = (e['type'] ?? '').toString();
            final details = [
              if (e['note'] != null && e['note'].toString().isNotEmpty) '“${e['note']}”',
              if (e['message'] != null) '“${e['message']}”',
              if (e['email'] != null) e['email'],
              if (e['sent'] != null) '${e['sent']} people',
            ].join(' · ');
            return ListTile(
              dense: true,
              title: Text(_eventLabels[type] ?? type, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text([
                'by ${e['byEmail'] ?? e['byUid']} · ${_when(e['at'] as Timestamp?)}',
                if (details.isNotEmpty) details,
              ].join('\n')),
              isThreeLine: details.isNotEmpty,
              onTap: e['uid'] != null
                  ? () => showUserAdminSheet(context, uid: e['uid'].toString(), isAdmin: true)
                  : e['businessId'] != null
                      ? () => showPageAdminSheet(context, businessId: e['businessId'].toString(), isAdmin: true)
                      : null,
            );
          },
        );
      },
    );
  }
}

// -------------------------------------------------------------------- team --

class _TeamTab extends StatelessWidget {
  const _TeamTab();

  Future<void> _add(BuildContext context) async {
    final email = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Add a moderator'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('They need a Duhuze account with this email. Moderators handle reports '
              'and suspend users; they cannot change the team or open the ghost archive.'),
          TextField(
            controller: email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Email'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Add')),
        ],
      ),
    );
    final value = email.text.trim();
    email.dispose();
    if (ok != true || value.isEmpty || !context.mounted) return;
    await _run(context, () => AdminService.instance.setModerator(value, true),
        'Added. They must sign out and in again.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(context),
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: const Text('Add moderator'),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: AdminService.instance.staff(),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final docs = snap.data!.docs;
          return ListView(
            padding: const EdgeInsets.only(bottom: 90),
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Everyone here gets a notification for every new report. '
                  'Admins are changed only from the PC (functions/scripts/set-admin.js).',
                  style: TextStyle(color: AppColors.grey),
                ),
              ),
              if (docs.isEmpty)
                const ListTile(title: Text('No team members listed yet. Run set-admin.js once for yourself.')),
              for (final d in docs)
                ListTile(
                  leading: Icon(d.data()['role'] == 'admin' ? Icons.verified_user_rounded : Icons.shield_outlined,
                      color: AppColors.primary),
                  title: Text((d.data()['email'] ?? d.id).toString()),
                  subtitle: Text((d.data()['role'] ?? '').toString()),
                  trailing: d.data()['role'] == 'moderator'
                      ? IconButton(
                          tooltip: 'Remove moderator',
                          icon: const Icon(Icons.remove_circle_outline_rounded, color: AppColors.error),
                          onPressed: () async {
                            if (!await _confirm(context, 'Remove moderator?',
                                '${d.data()['email']} will lose access to the panel.')) {
                              return;
                            }
                            if (!context.mounted) return;
                            await _run(context,
                                () => AdminService.instance.setModerator(d.data()['email'].toString(), false),
                                'Removed');
                          },
                        )
                      : null,
                ),
            ],
          );
        },
      ),
    );
  }
}
