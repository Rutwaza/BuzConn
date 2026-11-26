import 'package:businessfinder/core/i18n/tr.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../../features/billing/billing_service.dart';

/// Page team: the owner adds people by @username.
///   Admin  - edits the page, posts as the page, runs the shop and orders.
///   Editor - posts as the page.
/// Team members see this too (read only) and can leave.
class PageTeamPage extends StatefulWidget {
  const PageTeamPage({super.key, required this.pageId});
  final String pageId;

  @override
  State<PageTeamPage> createState() => _PageTeamPageState();
}

class _PageTeamPageState extends State<PageTeamPage> {
  bool _busy = false;

  String get _me => FirebaseAuth.instance.currentUser?.uid ?? '';

  Future<void> _run(Map<String, Object?> data, String done) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await BillingService.instance.team({'pageId': widget.pageId, ...data});
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('HttpException: ', ''))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final name = TextEditingController();
    var role = 'editor';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(tr('Add to the team')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: InputDecoration(
                labelText: tr('Username'),
                prefixText: '@',
                helperText: tr('They must have a Duhuze username.'),
              ),
            ),
            const SizedBox(height: 14),
            _RolePicker(value: role, onChanged: (r) => set(() => role = r)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Add'))),
          ],
        ),
      ),
    );
    if (ok == true && name.text.trim().isNotEmpty) {
      await _run({'action': 'add', 'username': name.text.trim(), 'role': role},
          tr('Added to the team'));
    }
  }

  Future<void> _memberMenu(String uid, String role) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (role != 'admin')
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_rounded),
              title: Text(tr('Make admin')),
              subtitle: Text(tr('Can edit the page, run the shop and orders')),
              onTap: () => Navigator.pop(c, 'admin'),
            ),
          if (role != 'editor')
            ListTile(
              leading: const Icon(Icons.edit_note_rounded),
              title: Text(tr('Make editor')),
              subtitle: Text(tr('Can post as the page')),
              onTap: () => Navigator.pop(c, 'editor'),
            ),
          ListTile(
            leading: const Icon(Icons.person_remove_rounded, color: AppColors.error),
            title: Text(tr('Remove from team'),
                style: const TextStyle(color: AppColors.error)),
            onTap: () => Navigator.pop(c, 'remove'),
          ),
        ]),
      ),
    );
    if (choice == null) return;
    if (choice == 'remove') {
      await _run({'action': 'remove', 'uid': uid}, tr('Removed from the team'));
    } else {
      await _run({'action': 'role', 'uid': uid, 'role': choice}, tr('Role changed'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('businesses')
          .doc(widget.pageId)
          .snapshots(),
      builder: (context, snap) {
        final page = snap.data?.data();
        final ownerId = (page?['ownerId'] ?? '').toString();
        final team = Map<String, dynamic>.from(page?['team'] as Map? ?? {});
        final isOwner = ownerId == _me;
        final members = team.entries.toList()
          ..sort((a, b) => a.value == b.value ? 0 : (a.value == 'admin' ? -1 : 1));

        return Scaffold(
          appBar: AppBar(
            title: Text('${tr('Team')} · ${page?['name'] ?? ''}'),
            bottom: _busy
                ? const PreferredSize(
                    preferredSize: Size.fromHeight(2),
                    child: LinearProgressIndicator(minHeight: 2))
                : null,
          ),
          floatingActionButton: isOwner
              ? FloatingActionButton.extended(
                  onPressed: _busy ? null : _add,
                  icon: const Icon(Icons.person_add_alt_1_rounded),
                  label: Text(tr('Add person')),
                )
              : null,
          body: page == null
              ? const Center(child: CircularProgressIndicator())
              : Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                      children: [
                        _Explainer(),
                        const SizedBox(height: 12),
                        _MemberTile(uid: ownerId, role: 'owner'),
                        for (final m in members)
                          _MemberTile(
                            uid: m.key,
                            role: m.value.toString(),
                            onTap: isOwner ? () => _memberMenu(m.key, m.value.toString()) : null,
                          ),
                        if (members.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              isOwner
                                  ? tr('No one else yet. Add people who help you run this page.')
                                  : tr('No one else yet.'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: AppColors.grey),
                            ),
                          ),
                        if (!isOwner && team.containsKey(_me)) ...[
                          const SizedBox(height: 20),
                          OutlinedButton.icon(
                            onPressed: _busy
                                ? null
                                : () async {
                                    final nav = Navigator.of(context);
                                    await _run({'action': 'leave'}, tr('You left the team'));
                                    nav.pop();
                                  },
                            style: OutlinedButton.styleFrom(foregroundColor: AppColors.error),
                            icon: const Icon(Icons.logout_rounded),
                            label: Text(tr('Leave this team')),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
        );
      },
    );
  }
}

class _Explainer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    Widget row(IconData i, String t, String s) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(i, size: 20, color: AppColors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text.rich(TextSpan(children: [
                TextSpan(text: '$t  ', style: const TextStyle(fontWeight: FontWeight.w800)),
                TextSpan(text: s, style: const TextStyle(color: AppColors.grey)),
              ])),
            ),
          ]),
        );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(children: [
        row(Icons.workspace_premium_rounded, tr('Owner'),
            tr('Everything, including the team and hiding the page.')),
        row(Icons.admin_panel_settings_rounded, tr('Admin'),
            tr('Edits the page, posts, runs the shop and orders.')),
        row(Icons.edit_note_rounded, tr('Editor'), tr('Posts as the page.')),
      ]),
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({required this.uid, required this.role, this.onTap});
  final String uid;
  final String role;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: FirebaseFirestore.instance.collection('users').doc(uid).get(),
      builder: (context, snap) {
        final u = snap.data?.data() ?? {};
        final name = (u['name'] ?? '...').toString();
        final username = (u['username'] ?? '').toString();
        final photo = (u['imageUrl'] ?? '').toString();
        final color = role == 'owner'
            ? AppColors.gold
            : role == 'admin'
                ? AppColors.primary
                : AppColors.secondary;
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: ListTile(
            onTap: onTap,
            leading: CircleAvatar(
              backgroundColor: AppColors.primary.withValues(alpha: 0.15),
              backgroundImage: photo.isNotEmpty ? CachedNetworkImageProvider(photo) : null,
              child: photo.isEmpty ? Text(name.isEmpty ? '?' : name[0].toUpperCase()) : null,
            ),
            title: Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: username.isEmpty ? null : Text('@$username'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  {'owner': tr('Owner'), 'admin': tr('Admin'), 'editor': tr('Editor')}[role] ?? role,
                  style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12),
                ),
              ),
              if (onTap != null) const Icon(Icons.more_vert_rounded),
            ]),
          ),
        );
      },
    );
  }
}

class _RolePicker extends StatelessWidget {
  const _RolePicker({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<String>(
      segments: [
        ButtonSegment(
            value: 'editor', icon: const Icon(Icons.edit_note_rounded), label: Text(tr('Editor'))),
        ButtonSegment(
            value: 'admin',
            icon: const Icon(Icons.admin_panel_settings_rounded),
            label: Text(tr('Admin'))),
      ],
      selected: {value},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}
