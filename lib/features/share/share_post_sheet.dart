import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/i18n/tr.dart';
import '../../core/theme/colors.dart';
import '../../core/widgets/emoji_picker.dart';
import '../../data/models/post_model.dart';
import '../chat/data/chat_repository.dart';
import '../chat/ui/people_picker.dart';
import '../status/data/status_repository.dart';

/// The public link of a post (opens the app, or a preview page).
String postLink(String postId) => 'https://duhuze-rw.web.app/p/$postId';

/// What a shared post looks like inside a chat message (`sharedPost`).
Map<String, dynamic> sharedPostPayload(Post post) {
  final first = post.media.isNotEmpty ? post.media.first : null;
  return {
    'postId': post.id,
    'by': post.businessName,
    'text': post.content.length > 160
        ? '${post.content.substring(0, 157)}…'
        : post.content,
    'imageUrl': first == null
        ? null
        : (first.isVideo ? first.thumbnailUrl : first.url),
    'isVideo': first?.isVideo ?? false,
  };
}

/// Share sheet: send to chats (several at once, with a note), add to your
/// story, copy the link, or open the phone/PC share menu.
Future<void> showSharePostSheet(BuildContext context, Post post) {
  HapticFeedback.selectionClick();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (_) => _ShareSheet(post: post),
  );
}

class _Target {
  _Target({required this.key, required this.title, this.imageUrl,
      this.chatId, this.userId, this.isGroup = false});
  final String key;
  final String title;
  final String? imageUrl;
  final String? chatId; // existing chat
  final String? userId; // person without a chat yet
  final bool isGroup;
}

class _ShareSheet extends StatefulWidget {
  const _ShareSheet({required this.post});
  final Post post;

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  final _note = TextEditingController();
  final Map<String, _Target> _picked = {};
  List<_Target> _recent = [];
  bool _loading = true;
  bool _sending = false;

  String get _me => FirebaseAuth.instance.currentUser?.uid ?? '';

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('chats')
          .where('participants', arrayContains: _me)
          .limit(60)
          .get();
      final docs = snap.docs.toList()
        ..sort((a, b) {
          final at = (a.data()['lastMessageAt'] as Timestamp?)?.millisecondsSinceEpoch ?? 0;
          final bt = (b.data()['lastMessageAt'] as Timestamp?)?.millisecondsSinceEpoch ?? 0;
          return bt.compareTo(at);
        });
      final out = <_Target>[];
      for (final d in docs.take(16)) {
        final c = d.data();
        if (c['requestStatus'] == 'rejected') continue;
        final type = (c['chatType'] ?? '').toString();
        String title;
        String? img;
        if (type == 'group') {
          title = (c['groupName'] ?? 'Group').toString();
          img = c['groupImageUrl'] as String?;
        } else if (type == 'direct') {
          final isA = c['userAId'] == _me;
          title = (isA ? c['userBName'] : c['userAName'] ?? 'Chat').toString();
          img = (isA ? c['userBImageUrl'] : c['userAImageUrl']) as String?;
        } else {
          final owner = c['businessOwnerId'] == _me;
          title = (owner ? c['clientName'] : c['businessName'] ?? 'Chat').toString();
          img = (owner ? c['clientImageUrl'] : c['businessImageUrl']) as String?;
        }
        out.add(_Target(key: 'c:${d.id}', title: title, imageUrl: img,
            chatId: d.id, isGroup: type == 'group'));
      }
      if (mounted) setState(() => _recent = out);
    } catch (_) {
      // No chats yet: the "More people" button still works.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toggle(_Target t) => setState(() {
        if (_picked.remove(t.key) == null) _picked[t.key] = t;
      });

  Future<void> _morePeople() async {
    final people = await pickPeople(context,
        title: tr('Send to'), confirmLabel: tr('Done'));
    if (people == null) return;
    setState(() {
      for (final p in people) {
        final t = _Target(key: 'u:${p.uid}', title: p.name,
            imageUrl: p.imageUrl, userId: p.uid);
        _picked[t.key] = t;
        if (!_recent.any((r) => r.key == t.key)) _recent.insert(0, t);
      }
    });
  }

  Future<void> _send() async {
    if (_picked.isEmpty || _sending) return;
    setState(() => _sending = true);
    final repo = ChatRepository();
    final note = _note.text.trim();
    var ok = 0;
    var failed = 0;
    for (final t in _picked.values) {
      try {
        final chatId = t.chatId ??
            await repo.createOrGetDirectChat(userAId: _me, userBId: t.userId!);
        await repo.sendMessage(
          chatId: chatId,
          senderId: _me,
          text: note.isNotEmpty ? note : '📮 ${tr('Shared a post')}',
          extra: {
            'sharedPost': sharedPostPayload(widget.post),
            'shareNoteEmpty': note.isEmpty,
          },
        );
        ok++;
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    messenger.showSnackBar(SnackBar(
      content: Text(failed == 0
          ? '${tr('Sent to')} $ok ${ok == 1 ? tr('chat') : tr('chats')} ✓'
          : '${tr('Sent')}: $ok · ${tr('Not sent')}: $failed'),
    ));
  }

  Future<void> _addToStory() async {
    final p = widget.post;
    final first = p.media.isNotEmpty ? p.media.first : null;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    try {
      await StatusRepository.instance.sharePost(
        postId: p.id,
        postBy: p.businessName,
        caption: p.content,
        imageUrl: first == null
            ? null
            : (first.isVideo ? first.thumbnailUrl : first.url),
      );
      messenger.showSnackBar(
          SnackBar(content: Text(tr('Added to your status for 24 hours ✓'))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final post = widget.post;
    final thumb = post.media.isNotEmpty
        ? (post.media.first.isVideo
            ? post.media.first.thumbnailUrl
            : post.media.first.url)
        : null;
    final link = postLink(post.id);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.all(10),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF141821) : Colors.white,
            borderRadius: BorderRadius.circular(26),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white24 : Colors.black12,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 52,
                    height: 52,
                    child: thumb == null
                        ? ColoredBox(
                            color: AppColors.primary.withValues(alpha: 0.15),
                            child: const Icon(Icons.notes_rounded,
                                color: AppColors.primary))
                        : CachedNetworkImage(
                            imageUrl: thumb,
                            fit: BoxFit.cover,
                            memCacheWidth: 160),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tr('Share'),
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w800)),
                      Text(
                        post.content.trim().isEmpty
                            ? post.businessName
                            : '${post.businessName} · ${post.content.trim()}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.grey),
                      ),
                    ],
                  ),
                ),
              ]),
              const SizedBox(height: 14),
              Text(tr('Send to'),
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, color: AppColors.grey)),
              const SizedBox(height: 8),
              SizedBox(
                height: 92,
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          _Bubble(
                            label: tr('Search'),
                            selected: false,
                            onTap: _morePeople,
                            child: CircleAvatar(
                              radius: 27,
                              backgroundColor:
                                  AppColors.primary.withValues(alpha: 0.12),
                              child: const Icon(Icons.search_rounded,
                                  color: AppColors.primary),
                            ),
                          ),
                          for (final t in _recent)
                            _Bubble(
                              label: t.title,
                              selected: _picked.containsKey(t.key),
                              onTap: () => _toggle(t),
                              child: CircleAvatar(
                                radius: 27,
                                backgroundColor: AppColors.primary,
                                backgroundImage: t.imageUrl == null ||
                                        t.imageUrl!.isEmpty
                                    ? null
                                    : CachedNetworkImageProvider(t.imageUrl!),
                                child: t.imageUrl == null || t.imageUrl!.isEmpty
                                    ? (t.isGroup
                                        ? const Icon(Icons.groups_rounded,
                                            color: Colors.white)
                                        : Text(
                                            t.title.isEmpty
                                                ? '?'
                                                : t.title[0].toUpperCase(),
                                            style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.w700)))
                                    : null,
                              ),
                            ),
                        ],
                      ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                child: _picked.isEmpty
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(children: [
                          Expanded(
                            child: TextField(
                              controller: _note,
                              minLines: 1,
                              maxLines: 3,
                              decoration: InputDecoration(
                                hintText: tr('Add a message…'),
                                isDense: true,
                                filled: true,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(22),
                                  borderSide: BorderSide.none,
                                ),
                                suffixIcon: EmojiButton(controller: _note),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            onPressed: _sending ? null : _send,
                            icon: _sending
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white))
                                : const Icon(Icons.send_rounded, size: 18),
                            label: Text(_picked.length == 1
                                ? tr('Send')
                                : '${tr('Send')} (${_picked.length})'),
                          ),
                        ]),
                      ),
              ),
              const SizedBox(height: 14),
              const Divider(height: 1),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _Action(
                    icon: Icons.add_circle_outline_rounded,
                    label: tr('Add to story'),
                    color: const Color(0xFFE1306C),
                    onTap: _addToStory,
                  ),
                  _Action(
                    icon: Icons.link_rounded,
                    label: tr('Copy link'),
                    color: AppColors.primary,
                    onTap: () async {
                      await Clipboard.setData(ClipboardData(text: link));
                      if (!context.mounted) return;
                      final messenger = ScaffoldMessenger.of(context);
                      Navigator.pop(context);
                      messenger.showSnackBar(
                          SnackBar(content: Text(tr('Link copied'))));
                    },
                  ),
                  _Action(
                    icon: Icons.ios_share_rounded,
                    label: tr('Share to…'),
                    color: const Color(0xFF25D366),
                    onTap: () async {
                      final text = post.content.trim().isEmpty
                          ? '${post.businessName} ${tr('on Duhuze')}'
                          : '${post.businessName}: ${post.content.trim()}';
                      Navigator.pop(context);
                      await Share.share('$text\n\n$link',
                          subject: '${post.businessName} · Duhuze');
                    },
                  ),
                  _Action(
                    icon: Icons.copy_all_rounded,
                    label: tr('Copy text'),
                    color: Colors.orange,
                    onTap: () async {
                      await Clipboard.setData(ClipboardData(
                          text: post.content.trim().isEmpty
                              ? link
                              : '${post.content.trim()}\n$link'));
                      if (!context.mounted) return;
                      final messenger = ScaffoldMessenger.of(context);
                      Navigator.pop(context);
                      messenger.showSnackBar(
                          SnackBar(content: Text(tr('Caption copied'))));
                    },
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

class _Bubble extends StatelessWidget {
  const _Bubble({required this.label, required this.selected,
      required this.onTap, required this.child});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: 64,
          child: Column(children: [
            Stack(children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? AppColors.primary : Colors.transparent,
                    width: 2.5,
                  ),
                ),
                child: child,
              ),
              if (selected)
                const Positioned(
                  right: 0,
                  bottom: 0,
                  child: CircleAvatar(
                    radius: 10,
                    backgroundColor: AppColors.primary,
                    child: Icon(Icons.check, size: 13, color: Colors.white),
                  ),
                ),
            ]),
            const SizedBox(height: 4),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w500)),
          ]),
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label,
      required this.color, required this.onTap});
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: color.withValues(alpha: 0.13),
            child: Icon(icon, color: color),
          ),
          const SizedBox(height: 6),
          Text(label,
              style:
                  const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

/// A shared post inside a chat bubble: photo, who posted, first words.
class SharedPostBubble extends StatelessWidget {
  const SharedPostBubble({super.key, required this.data, required this.onOpen});
  final Map<String, dynamic> data;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final img = data['imageUrl'] as String?;
    final text = (data['text'] ?? '').toString();
    return GestureDetector(
      onTap: onOpen,
      child: Container(
        width: 240,
        margin: const EdgeInsets.only(top: 2, bottom: 4),
        decoration: BoxDecoration(
          color: isDark ? Colors.black26 : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: isDark ? Colors.white12 : Colors.black.withValues(alpha: 0.08)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (img != null && img.isNotEmpty)
              Stack(children: [
                CachedNetworkImage(
                  imageUrl: img,
                  height: 160,
                  width: 240,
                  fit: BoxFit.cover,
                  memCacheWidth: 480,
                ),
                if (data['isVideo'] == true)
                  const Positioned.fill(
                    child: Center(
                      child: Icon(Icons.play_circle_fill_rounded,
                          size: 44, color: Colors.white),
                    ),
                  ),
              ]),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.dynamic_feed_rounded,
                        size: 14, color: AppColors.primary),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text((data['by'] ?? 'Duhuze').toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 13,
                              color: isDark ? Colors.white : Colors.black87)),
                    ),
                  ]),
                  if (text.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(text,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12.5,
                            color: isDark ? Colors.white70 : Colors.black54)),
                  ],
                  const SizedBox(height: 6),
                  Text(tr('Tap to view post'),
                      style: const TextStyle(
                          color: AppColors.primary,
                          fontSize: 12,
                          fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
