import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/colors.dart';
import 'admin_service.dart';

/// The Admin panel: Reports, Users, Team. Only shown to staff (Settings and
/// report notifications). Guide: README -> "Admin panel".
class AdminPanelPage extends StatefulWidget {
  const AdminPanelPage({super.key});

  @override
  State<AdminPanelPage> createState() => _AdminPanelPageState();
}

class _AdminPanelPageState extends State<AdminPanelPage> {
  StaffRole? _role;

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
    return DefaultTabController(
      length: isAdmin ? 3 : 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(isAdmin ? 'Admin panel' : 'Moderator panel'),
          bottom: TabBar(tabs: [
            const Tab(icon: Icon(Icons.flag_rounded), text: 'Reports'),
            const Tab(icon: Icon(Icons.people_alt_rounded), text: 'Users'),
            if (isAdmin) const Tab(icon: Icon(Icons.shield_rounded), text: 'Team'),
          ]),
        ),
        body: TabBarView(children: [
          const _ReportsTab(),
          const _UsersTab(),
          if (isAdmin) const _TeamTab(),
        ]),
      ),
    );
  }
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
  late Future<Map<String, dynamic>> _stats = AdminService.instance.stats();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        FutureBuilder<Map<String, dynamic>>(
          future: _stats,
          builder: (context, snap) {
            final s = snap.data;
            if (s == null) return const SizedBox(height: 8);
            Widget pill(String label, Object? v, {Color? color}) => Chip(
                  label: Text('$label: $v'),
                  backgroundColor: color?.withValues(alpha: 0.12),
                  labelStyle: TextStyle(color: color, fontWeight: FontWeight.w600),
                );
            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: Wrap(spacing: 6, runSpacing: 6, children: [
                if ((s['urgentReports'] ?? 0) > 0)
                  pill('URGENT', s['urgentReports'], color: AppColors.error),
                pill('Open reports', s['openReports'], color: AppColors.primary),
                pill('Users', s['users']),
                pill('Pages', s['pages']),
                pill('Posts', s['posts']),
                pill('Suspended', s['suspended']),
              ]),
            );
          },
        ),
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
                  onChanged: () => setState(() => _stats = AdminService.instance.stats()),
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

// ------------------------------------------------------------------- users --

class _UsersTab extends StatefulWidget {
  const _UsersTab();

  @override
  State<_UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends State<_UsersTab> {
  final _search = TextEditingController();
  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>? _results;
  bool _showSuspended = false;

  @override
  void initState() {
    super.initState();
    _results = AdminService.instance.suspendedUsers();
    _showSuspended = true;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _find() => setState(() {
        _showSuspended = false;
        _results = AdminService.instance.searchUsers(_search.text);
      });

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: _search,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _find(),
          decoration: InputDecoration(
            hintText: 'Search a name or username (one word)',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward_rounded), onPressed: _find),
            border: const OutlineInputBorder(),
          ),
        ),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(_showSuspended ? 'Suspended users' : 'Search results',
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
      ),
      Expanded(
        child: FutureBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
          future: _results,
          builder: (context, snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final users = snap.data!;
            if (users.isEmpty) {
              return Center(child: Text(_showSuspended ? 'Nobody is suspended.' : 'No users found.'));
            }
            return ListView(children: [
              for (final u in users)
                _UserRow(
                  doc: u,
                  onChanged: () => setState(() {
                    _results = _showSuspended
                        ? AdminService.instance.suspendedUsers()
                        : AdminService.instance.searchUsers(_search.text);
                  }),
                ),
            ]);
          },
        ),
      ),
    ]);
  }
}

class _UserRow extends StatelessWidget {
  const _UserRow({required this.doc, required this.onChanged});
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final u = doc.data();
    final suspended = u['suspended'] == true;
    final img = u['imageUrl'] as String?;
    return ListTile(
      leading: CircleAvatar(
        backgroundImage: img?.startsWith('http') == true ? CachedNetworkImageProvider(img!) : null,
      ),
      title: Text((u['name'] ?? u['username'] ?? doc.id).toString()),
      subtitle: Text(suspended ? 'SUSPENDED' : '@${u['username'] ?? '-'}',
          style: TextStyle(color: suspended ? AppColors.error : null)),
      onTap: () => context.push(AppRoutes.clientProfilePath(doc.id)),
      trailing: suspended
          ? TextButton(
              onPressed: () async {
                await _run(context, () => AdminService.instance.setSuspended(doc.id, false), 'Restored');
                onChanged();
              },
              child: const Text('Restore'),
            )
          : TextButton(
              style: TextButton.styleFrom(foregroundColor: AppColors.error),
              onPressed: () async {
                if (!await _confirm(context, 'Suspend this user?',
                    'They are logged out and cannot sign in until you restore them.')) {
                  return;
                }
                if (!context.mounted) return;
                await _run(context, () => AdminService.instance.setSuspended(doc.id, true), 'Suspended');
                onChanged();
              },
              child: const Text('Suspend'),
            ),
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
