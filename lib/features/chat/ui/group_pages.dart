import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/i18n/tr.dart';
import '../../../core/services/media_picker.dart';
import '../../../core/services/r2_storage_service.dart';
import '../../../core/theme/colors.dart';
import '../../../core/widgets/emoji_picker.dart';
import '../../../core/widgets/verified_badge.dart';
import '../../moderation/moderation.dart';
import '../data/chat_repository.dart';
import '../data/group_service.dart';
import 'people_picker.dart';
import 'package:businessfinder/core/widgets/app_toast.dart';

Future<String?> _uploadGroupPhoto() async {
  final f = await MediaPicker.pickImage(maxWidth: 720);
  if (f == null) return null;
  final Uint8List bytes = await f.readAsBytes();
  return R2StorageService.instance.uploadImage(
    bucket: 'post-images',
    path: 'groups/${DateTime.now().microsecondsSinceEpoch}.jpg',
    bytes: bytes,
  );
}

Widget groupAvatar(String? url, String name, {double radius = 22}) {
  return CircleAvatar(
    radius: radius,
    backgroundColor: AppColors.primary.withValues(alpha: 0.85),
    backgroundImage:
        url == null || url.isEmpty ? null : CachedNetworkImageProvider(url),
    child: url == null || url.isEmpty
        ? Icon(Icons.groups_rounded, color: Colors.white, size: radius)
        : null,
  );
}

/// New group: 1) choose people, 2) name + photo. Opens the chat after.
Future<void> startNewGroup(BuildContext context) async {
  final people = await pickPeople(context,
      title: tr('New group'), confirmLabel: tr('Next'));
  if (people == null || people.isEmpty || !context.mounted) return;
  final chatId = await Navigator.of(context).push<String>(
    MaterialPageRoute(builder: (_) => _NewGroupDetailsPage(people: people)),
  );
  if (chatId != null && context.mounted) {
    context.push(AppRoutes.chatDetailPath(chatId));
  }
}

class _NewGroupDetailsPage extends StatefulWidget {
  const _NewGroupDetailsPage({required this.people});
  final List<PickedPerson> people;

  @override
  State<_NewGroupDetailsPage> createState() => _NewGroupDetailsPageState();
}

class _NewGroupDetailsPageState extends State<_NewGroupDetailsPage> {
  final _name = TextEditingController();
  final _about = TextEditingController();
  String? _photo;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_name.text.trim().isEmpty || _busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final id = await GroupService.instance.create(
        name: _name.text.trim(),
        description: _about.text.trim(),
        imageUrl: _photo,
        memberIds: widget.people.map((p) => p.uid).toList(),
      );
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Group details'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _create,
        icon: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.check_rounded),
        label: Text(tr('Create group')),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Center(
                child: GestureDetector(
                  onTap: () async {
                    final url = await _uploadGroupPhoto();
                    if (url != null && mounted) setState(() => _photo = url);
                  },
                  child: Stack(children: [
                    groupAvatar(_photo, _name.text, radius: 48),
                    const Positioned(
                      right: 0,
                      bottom: 0,
                      child: CircleAvatar(
                        radius: 16,
                        backgroundColor: AppColors.primary,
                        child: Icon(Icons.camera_alt_rounded,
                            size: 16, color: Colors.white),
                      ),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _name,
                maxLength: 60,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: tr('Group name'),
                  suffixIcon: EmojiButton(controller: _name),
                ),
              ),
              TextField(
                controller: _about,
                maxLength: 300,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: tr('Description (optional)'),
                  suffixIcon: EmojiButton(controller: _about),
                ),
              ),
              const SizedBox(height: 8),
              Text('${tr('Members')}: ${widget.people.length + 1}',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in widget.people)
                    Chip(
                      avatar: CircleAvatar(
                        backgroundImage: p.imageUrl == null
                            ? null
                            : CachedNetworkImageProvider(p.imageUrl!),
                        child: p.imageUrl == null
                            ? Text(p.name.isEmpty ? '?' : p.name[0])
                            : null,
                      ),
                      label: Text(p.name),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Join a group" from a link or code.
Future<void> joinGroupDialog(BuildContext context, {String? initial}) async {
  final c = TextEditingController(text: initial ?? '');
  final code = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(tr('Join a group')),
      content: TextField(
        controller: c,
        autofocus: true,
        decoration: InputDecoration(
          hintText: tr('Paste the invite link or code'),
        ),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Cancel'))),
        FilledButton(
            onPressed: () => Navigator.pop(context, c.text),
            child: Text(tr('Next'))),
      ],
    ),
  );
  if (code == null || code.trim().isEmpty || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    final cleaned = GroupService.codeFrom(code);
    final info = await GroupService.instance.preview(cleaned);
    if (!context.mounted) return;
    if (info['alreadyMember'] == true) {
      context.push(AppRoutes.chatDetailPath(info['chatId'] as String));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            groupAvatar(info['imageUrl'] as String?, '', radius: 40),
            const SizedBox(height: 12),
            Text((info['name'] ?? '').toString(),
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            Text('${info['memberCount']} ${tr('members')}',
                style: const TextStyle(color: AppColors.grey)),
            if ((info['description'] ?? '').toString().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(info['description'].toString(), textAlign: TextAlign.center),
            ],
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr('Cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr('Join group'))),
        ],
      ),
    );
    if (ok != true) return;
    final chatId = await GroupService.instance.join(cleaned);
    if (context.mounted) context.push(AppRoutes.chatDetailPath(chatId));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
  }
}

/// Group info: photo, name, description, invite link, settings, members.
class GroupInfoPage extends StatelessWidget {
  const GroupInfoPage({super.key, required this.chatId});
  final String chatId;

  @override
  Widget build(BuildContext context) {
    final me = FirebaseAuth.instance.currentUser?.uid ?? '';
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('chats')
          .doc(chatId)
          .snapshots(),
      builder: (context, snap) {
        final g = snap.data?.data();
        if (snap.hasError) {
          // Not a member any more (left / removed).
          return Scaffold(
            appBar: AppBar(),
            body: Center(child: Text(tr('You are no longer in this group.'))),
          );
        }
        if (g == null) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        final members = (g['participants'] as List? ?? []).cast<String>();
        final admins = (g['admins'] as List? ?? []).cast<String>();
        final ownerId = (g['ownerId'] ?? '').toString();
        final isAdmin = admins.contains(me);
        final canEdit = isAdmin || g['onlyAdminsCanEditInfo'] == false;
        final name = (g['groupName'] ?? 'Group').toString();
        final about = (g['groupDescription'] ?? '').toString();
        final code = (g['inviteCode'] ?? '').toString();
        final svc = GroupService.instance;

        Future<void> run(Future<void> Function() f, [String? done]) async {
          final messenger = ScaffoldMessenger.of(context);
          try {
            await f();
            if (done != null) {
              messenger.showSnackBar(SnackBar(content: Text(done)));
            }
          } catch (e) {
            messenger.showSnackBar(SnackBar(content: Text('$e')));
          }
        }

        return Scaffold(
          appBar: AppBar(title: Text(tr('Group info'))),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(
                padding: const EdgeInsets.only(bottom: 40),
                children: [
                  const SizedBox(height: 20),
                  Center(
                    child: GestureDetector(
                      onTap: !canEdit
                          ? null
                          : () => run(() async {
                                final url = await _uploadGroupPhoto();
                                if (url != null) {
                                  await svc.updateInfo(chatId, imageUrl: url);
                                }
                              }),
                      child: Stack(children: [
                        groupAvatar(g['groupImageUrl'] as String?, name,
                            radius: 54),
                        if (canEdit)
                          const Positioned(
                            right: 0,
                            bottom: 0,
                            child: CircleAvatar(
                              radius: 17,
                              backgroundColor: AppColors.primary,
                              child: Icon(Icons.camera_alt_rounded,
                                  size: 17, color: Colors.white),
                            ),
                          ),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(name,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 22, fontWeight: FontWeight.w800)),
                      ),
                      if (canEdit)
                        IconButton(
                          tooltip: tr('Edit'),
                          icon: const Icon(Icons.edit_rounded, size: 18),
                          onPressed: () async {
                            final v = await _editText(context,
                                title: tr('Group name'), initial: name, max: 60);
                            if (v != null && v.trim().isNotEmpty) {
                              await run(() => svc.updateInfo(chatId, name: v));
                            }
                          },
                        ),
                    ],
                  ),
                  Center(
                    child: Text(
                        '${tr('Group')} · ${members.length} ${tr('members')}',
                        style: const TextStyle(color: AppColors.grey)),
                  ),
                  const SizedBox(height: 12),
                  _Section(children: [
                    ListTile(
                      leading: const Icon(Icons.info_outline_rounded),
                      title: Text(about.isEmpty
                          ? (canEdit
                              ? tr('Add a group description')
                              : tr('No description'))
                          : about),
                      trailing: canEdit ? const Icon(Icons.edit_rounded, size: 18) : null,
                      onTap: !canEdit
                          ? null
                          : () async {
                              final v = await _editText(context,
                                  title: tr('Description'),
                                  initial: about,
                                  max: 300,
                                  lines: 3);
                              if (v != null) {
                                await run(() =>
                                    svc.updateInfo(chatId, description: v));
                              }
                            },
                    ),
                  ]),
                  if (isAdmin && code.isNotEmpty)
                    _Section(title: tr('Invite'), children: [
                      ListTile(
                        leading: const Icon(Icons.link_rounded),
                        title: Text(GroupService.inviteLink(code),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${tr('Code')}: $code'),
                        trailing: IconButton(
                          tooltip: tr('Copy'),
                          icon: const Icon(Icons.copy_rounded),
                          onPressed: () async {
                            await Clipboard.setData(ClipboardData(
                                text: GroupService.inviteLink(code)));
                            if (context.mounted) {
                              showToast(context, tr('Invite link copied'));
                            }
                          },
                        ),
                      ),
                      ListTile(
                        leading: const Icon(Icons.refresh_rounded),
                        title: Text(tr('Reset invite link')),
                        subtitle: Text(tr('The old link stops working.')),
                        onTap: () => run(() => svc.resetInvite(chatId),
                            tr('New invite link made')),
                      ),
                    ]),
                  if (isAdmin)
                    _Section(title: tr('Group settings'), children: [
                      SwitchListTile(
                        secondary: const Icon(Icons.campaign_outlined),
                        title: Text(tr('Only admins can send messages')),
                        value: g['onlyAdminsCanSend'] == true,
                        onChanged: (v) => run(() =>
                            svc.settings(chatId, onlyAdminsCanSend: v)),
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.edit_note_rounded),
                        title: Text(tr('Only admins can edit group info')),
                        value: g['onlyAdminsCanEditInfo'] != false,
                        onChanged: (v) => run(() =>
                            svc.settings(chatId, onlyAdminsCanEditInfo: v)),
                      ),
                    ]),
                  _Section(
                    title: '${members.length} ${tr('members')}',
                    children: [
                      if (isAdmin)
                        ListTile(
                          leading: const CircleAvatar(
                            backgroundColor: AppColors.primary,
                            child: Icon(Icons.person_add_alt_1_rounded,
                                color: Colors.white),
                          ),
                          title: Text(tr('Add members'),
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700)),
                          onTap: () async {
                            final people = await pickPeople(context,
                                title: tr('Add members'),
                                confirmLabel: tr('Add'),
                                exclude: members.toSet());
                            if (people != null && people.isNotEmpty) {
                              await run(
                                  () => svc
                                      .addMembers(chatId,
                                          people.map((p) => p.uid).toList())
                                      .then((_) {}),
                                  tr('Members added'));
                            }
                          },
                        ),
                      FutureBuilder<List<PickedPerson>>(
                        future: loadPeopleByIds(members),
                        builder: (context, ps) {
                          final people = [...(ps.data ?? const <PickedPerson>[])]
                            ..sort((a, b) {
                              int rank(PickedPerson p) => p.uid == me
                                  ? 0
                                  : (p.uid == ownerId
                                      ? 1
                                      : (admins.contains(p.uid) ? 2 : 3));
                              return rank(a).compareTo(rank(b));
                            });
                          return Column(children: [
                            for (final p in people)
                              _MemberTile(
                                person: p,
                                isMe: p.uid == me,
                                isOwner: p.uid == ownerId,
                                isAdmin: admins.contains(p.uid),
                                onTap: p.uid == me
                                    ? null
                                    : () => _memberActions(context,
                                        person: p,
                                        iAmAdmin: isAdmin,
                                        iAmOwner: me == ownerId,
                                        theyAreAdmin: admins.contains(p.uid),
                                        theyAreOwner: p.uid == ownerId,
                                        run: run),
                              ),
                          ]);
                        },
                      ),
                    ],
                  ),
                  _Section(children: [
                    ListTile(
                      leading: const Icon(Icons.flag_outlined,
                          color: Colors.redAccent),
                      title: Text(tr('Report group'),
                          style: const TextStyle(color: Colors.redAccent)),
                      onTap: () => showReportSheet(context,
                          targetType: 'chat',
                          targetId: chatId,
                          targetOwnerId: ownerId,
                          preview: name),
                    ),
                    ListTile(
                      leading: const Icon(Icons.logout_rounded,
                          color: Colors.redAccent),
                      title: Text(tr('Leave group'),
                          style: const TextStyle(
                              color: Colors.redAccent,
                              fontWeight: FontWeight.w700)),
                      onTap: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: Text(tr('Leave group?')),
                            content: Text(me == ownerId
                                ? tr('Another admin will become the owner.')
                                : tr('You won\'t get messages from this group any more.')),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(c, false),
                                  child: Text(tr('Cancel'))),
                              FilledButton(
                                  style: FilledButton.styleFrom(
                                      backgroundColor: Colors.redAccent),
                                  onPressed: () => Navigator.pop(c, true),
                                  child: Text(tr('Leave'))),
                            ],
                          ),
                        );
                        if (ok != true || !context.mounted) return;
                        final nav = Navigator.of(context);
                        final messenger = ScaffoldMessenger.of(context);
                        try {
                          await svc.leave(chatId);
                          nav.popUntil((r) => r.isFirst);
                        } catch (e) {
                          messenger.showSnackBar(SnackBar(content: Text('$e')));
                        }
                      },
                    ),
                  ]),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _memberActions(
    BuildContext context, {
    required PickedPerson person,
    required bool iAmAdmin,
    required bool iAmOwner,
    required bool theyAreAdmin,
    required bool theyAreOwner,
    required Future<void> Function(Future<void> Function(), [String?]) run,
  }) async {
    final svc = GroupService.instance;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person_rounded),
              title: Text('${tr('View')} ${person.name}'),
              onTap: () => Navigator.pop(c, 'profile'),
            ),
            ListTile(
              leading: const Icon(Icons.chat_bubble_rounded),
              title: Text('${tr('Message')} ${person.name}'),
              onTap: () => Navigator.pop(c, 'message'),
            ),
            if (iAmAdmin && !theyAreAdmin)
              ListTile(
                leading: const Icon(Icons.admin_panel_settings_rounded),
                title: Text(tr('Make group admin')),
                onTap: () => Navigator.pop(c, 'promote'),
              ),
            if (iAmOwner && theyAreAdmin && !theyAreOwner)
              ListTile(
                leading: const Icon(Icons.remove_moderator_rounded),
                title: Text(tr('Remove as admin')),
                onTap: () => Navigator.pop(c, 'demote'),
              ),
            if (iAmAdmin && !theyAreOwner && (!theyAreAdmin || iAmOwner))
              ListTile(
                leading: const Icon(Icons.person_remove_rounded,
                    color: Colors.redAccent),
                title: Text('${tr('Remove')} ${person.name}',
                    style: const TextStyle(color: Colors.redAccent)),
                onTap: () => Navigator.pop(c, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case 'profile':
        context.push(AppRoutes.clientProfilePath(person.uid));
      case 'message':
        final me = FirebaseAuth.instance.currentUser!.uid;
        final id = await ChatRepository()
            .createOrGetDirectChat(userAId: me, userBId: person.uid);
        if (context.mounted) context.push(AppRoutes.chatDetailPath(id));
      case 'promote':
        await run(() => svc.makeAdmin(chatId, person.uid),
            '${person.name} ${tr('is now an admin')}');
      case 'demote':
        await run(() => svc.removeAdmin(chatId, person.uid));
      case 'remove':
        await run(() => svc.remove(chatId, person.uid));
    }
  }
}

Future<String?> _editText(BuildContext context,
    {required String title,
    required String initial,
    required int max,
    int lines = 1}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        maxLength: max,
        maxLines: lines,
        decoration: InputDecoration(suffixIcon: EmojiButton(controller: c)),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Cancel'))),
        FilledButton(
            onPressed: () => Navigator.pop(context, c.text.trim()),
            child: Text(tr('Save'))),
      ],
    ),
  );
}

class _Section extends StatelessWidget {
  const _Section({this.title, required this.children});
  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Card(
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Text(title!,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, color: AppColors.grey)),
              ),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.person,
    required this.isMe,
    required this.isOwner,
    required this.isAdmin,
    this.onTap,
  });
  final PickedPerson person;
  final bool isMe;
  final bool isOwner;
  final bool isAdmin;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final url = person.imageUrl;
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: AppColors.primary,
        backgroundImage:
            url == null || url.isEmpty ? null : CachedNetworkImageProvider(url),
        child: url == null || url.isEmpty
            ? Text(person.name.isEmpty ? '?' : person.name[0].toUpperCase(),
                style: const TextStyle(color: Colors.white))
            : null,
      ),
      title: Row(children: [
        Flexible(
            child: Text(isMe ? '${person.name} (${tr('you')})' : person.name,
                overflow: TextOverflow.ellipsis)),
        if (person.verified) ...[
          const SizedBox(width: 4),
          const VerifiedBadge(size: 14),
        ],
      ]),
      trailing: isOwner || isAdmin
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(isOwner ? tr('Owner') : tr('Admin'),
                  style: const TextStyle(
                      color: AppColors.primary,
                      fontSize: 11,
                      fontWeight: FontWeight.w800)),
            )
          : null,
    );
  }
}

/// Opened from a group invite link (https://duhuze-rw.web.app/g/<code>).
class JoinGroupLinkPage extends StatefulWidget {
  const JoinGroupLinkPage({super.key, required this.code});
  final String code;

  @override
  State<JoinGroupLinkPage> createState() => _JoinGroupLinkPageState();
}

class _JoinGroupLinkPageState extends State<JoinGroupLinkPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (FirebaseAuth.instance.currentUser == null) return;
      await joinGroupDialog(context, initial: widget.code);
      if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = FirebaseAuth.instance.currentUser != null;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Join a group'))),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.groups_rounded, size: 64, color: AppColors.primary),
            const SizedBox(height: 12),
            Text(signedIn
                ? tr('Opening the invite…')
                : tr('Sign in first, then open the link again.')),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => context.go(signedIn ? AppRoutes.feed : AppRoutes.login),
              child: Text(signedIn ? tr('Go to Duhuze') : tr('Sign in')),
            ),
          ]),
        ),
      ),
    );
  }
}
