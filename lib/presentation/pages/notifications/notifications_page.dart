import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:businessfinder/features/admin/admin_panel_page.dart';
import 'package:businessfinder/core/i18n/tr.dart';
import 'package:businessfinder/features/shop/ui/orders_page.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/notification_read_service.dart';
import '../../../core/theme/colors.dart';
import '../../../data/models/post_model.dart';
import '../business/post_detail_page.dart';

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  final Set<String> _selectedIds = {};
  Set<String> _currentVisibleNotificationIds = {};
  _NotificationFilter _filter = _NotificationFilter.all;
  bool get _selectionMode => _selectedIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _markAllRead();
  }

  Future<void> _markAllRead() async {
    try {
      await NotificationReadService.markAllRead();
    } catch (e) {
      debugPrint('Failed to mark notifications read: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('Failed to mark notifications read'))),
        );
      }
    }
  }

  Future<void> _deleteSelected() async {
    final batch = FirebaseFirestore.instance.batch();
    for (final id in _selectedIds) {
      final ref =
          FirebaseFirestore.instance.collection('notifications').doc(id);
      batch.delete(ref);
    }
    await batch.commit();
    setState(() {
      _selectedIds.clear();
    });
  }

  Future<void> _openNotificationTarget(_GroupedNotification item) async {
    if (item.type == 'message' || item.type == 'message_request') {
      if (item.chatId == null || !context.mounted) return;
      if (item.type == 'message_request') {
        context.push('${AppRoutes.chats}?filter=requests');
      } else {
        context.push(AppRoutes.chatDetailPath(item.chatId!));
      }
      return;
    }
    if (item.type == 'report') {
      if (!context.mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const AdminPanelPage(),
      ));
      return;
    }
    if (item.type == 'order') {
      if (!context.mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const OrdersPage(),
      ));
      return;
    }
    if (item.type == 'team') {
      final id = item.businessId;
      if (id == null || id.isEmpty || !context.mounted) return;
      context.push(AppRoutes.businessProfilePath(id));
      return;
    }
    if (item.type == 'billing' && item.postId == null) {
      if (!context.mounted) return;
      context.push(AppRoutes.businesses);
      return;
    }
    if (item.type == 'follow') {
      if (item.fromUserId.isEmpty || !context.mounted) return;
      context.push(AppRoutes.clientProfilePath(item.fromUserId));
      return;
    }
    if (item.postId == null) return;
    final postDoc = await FirebaseFirestore.instance
        .collection('posts')
        .doc(item.postId)
        .get();
    if (!postDoc.exists || !context.mounted) return;
    final post = Post.fromFirestore(postDoc);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PostDetailPage(post: post)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return Scaffold(body: Center(child: Text(tr('Please sign in.'))));
    }
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final selectedColor = theme.colorScheme.primary.withValues(alpha: 0.15);

    return Scaffold(
      appBar: AppBar(
        title: Text(_selectionMode
            ? 'Selected ${_selectedIds.length}'
            : 'Notifications'),
        actions: _selectionMode
            ? [
                IconButton(
                  icon: const Icon(Icons.select_all_rounded),
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    setState(() {
                      if (_selectedIds.length ==
                          _currentVisibleNotificationIds.length) {
                        _selectedIds.clear();
                      } else {
                        _selectedIds
                          ..clear()
                          ..addAll(_currentVisibleNotificationIds);
                      }
                    });
                  },
                  tooltip: tr('Select all'),
                ),
                IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: _deleteSelected,
                  tooltip: tr('Delete selected'),
                ),
              ]
            : [],
      ),
      body: StreamBuilder<QuerySnapshot>(
        // Newest 100 only (Phase 3); older ones are rarely opened.
        stream: FirebaseFirestore.instance
            .collection('notifications')
            .where('toUserId', isEqualTo: user.uid)
            .orderBy('createdAt', descending: true)
            .limit(100)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text('Error: ${snapshot.error}'),
            );
          }
          final docs = (snapshot.data?.docs ?? []).toList()
            ..sort((a, b) {
              final aData = a.data() as Map<String, dynamic>;
              final bData = b.data() as Map<String, dynamic>;
              final aTs = aData['createdAt'] as Timestamp?;
              final bTs = bData['createdAt'] as Timestamp?;
              final aMillis = aTs?.millisecondsSinceEpoch ?? 0;
              final bMillis = bTs?.millisecondsSinceEpoch ?? 0;
              return bMillis.compareTo(aMillis);
            });

          if (docs.isEmpty) {
            return _NotificationsEmptyState(
              title: tr('You are all caught up'),
              subtitle: tr('New likes, follows and comments will show up here.'),
            );
          }
          final grouped = _groupNotifications(docs)
              .where((item) => _matchesFilter(item))
              .toList();
          _currentVisibleNotificationIds =
              grouped.expand((item) => item.ids).toSet();
          if (grouped.isEmpty) {
            return _NotificationsEmptyState(
              title: tr('Nothing for this filter'),
              subtitle: tr('Try another tab to see more activity.'),
            );
          }

          final sections = _buildSections(grouped);

          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
            children: [
              _NotificationsHeroCard(total: grouped.length),
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildFilterChip(_NotificationFilter.all, 'All'),
                    _buildFilterChip(_NotificationFilter.messages, 'Messages'),
                    _buildFilterChip(_NotificationFilter.activity, 'Activity'),
                    _buildFilterChip(_NotificationFilter.follows, 'Follows'),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              for (final section in sections.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
                  child: Text(
                    section.key,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                ...section.value.map(
                  (item) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _buildNotificationCard(
                      item,
                      selectedColor: selectedColor,
                      isDark: isDark,
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildFilterChip(_NotificationFilter filter, String label) {
    final selected = _filter == filter;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        selected: selected,
        label: Text(label),
        onSelected: (_) {
          HapticFeedback.selectionClick();
          setState(() => _filter = filter);
        },
      ),
    );
  }

  bool _matchesFilter(_GroupedNotification item) {
    switch (_filter) {
      case _NotificationFilter.all:
        return true;
      case _NotificationFilter.messages:
        return item.type == 'message' || item.type == 'message_request';
      case _NotificationFilter.activity:
        return item.type == 'like' ||
            item.type == 'comment' ||
            item.type == 'mention';
      case _NotificationFilter.follows:
        return item.type == 'follow';
    }
  }

  Map<String, List<_GroupedNotification>> _buildSections(
    List<_GroupedNotification> items,
  ) {
    final now = DateTime.now();
    final map = <String, List<_GroupedNotification>>{};
    for (final item in items) {
      final diff = now.difference(item.createdAt);
      final key = item.isUnread
          ? 'New'
          : diff.inDays == 0
              ? 'Today'
              : 'Earlier';
      map.putIfAbsent(key, () => []).add(item);
    }
    return map;
  }

  List<_GroupedNotification> _groupNotifications(
      List<QueryDocumentSnapshot> docs) {
    final grouped = <_GroupedNotification>[];
    for (final doc in docs) {
      final data = doc.data() as Map<String, dynamic>;
      final createdAt =
          (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now();
      final type = (data['type'] ?? 'activity').toString();
      final fromUserId = (data['fromUserId'] ?? '').toString();
      final postId = data['postId'] as String?;
      final chatId = data['chatId'] as String?;
      final readAt = data['readAt'] as Timestamp?;
      final preview = data['preview'] as String?;
      final key = '$type|$fromUserId|${postId ?? ''}|${chatId ?? ''}'
          // Each order update is its own line.
          '${const {'order', 'report', 'admin', 'review', 'billing', 'team', 'mention'}.contains(type) ? '|${doc.id}' : ''}';

      final last = grouped.isNotEmpty ? grouped.last : null;
      final canMerge = last != null &&
          last.groupKey == key &&
          createdAt.difference(last.createdAt).abs().inHours < 6;

      if (canMerge) {
        last.ids.add(doc.id);
        last.count += 1;
        last.preview = preview ?? last.preview;
        if (readAt == null) last.isUnread = true;
        continue;
      }

      grouped.add(
        _GroupedNotification(
          ids: [doc.id],
          groupKey: key,
          type: type,
          fromUserId: fromUserId,
          fromName: (data['fromUserName'] ?? 'Someone').toString(),
          fromImage: data['fromUserImageUrl'] as String?,
          postId: postId,
          chatId: chatId,
          businessId: data['businessId'] as String?,
          preview: preview,
          createdAt: createdAt,
          count: 1,
          isUnread: readAt == null,
        ),
      );
    }
    return grouped;
  }

  Widget _buildNotificationCard(
    _GroupedNotification item, {
    required Color selectedColor,
    required bool isDark,
  }) {
    final selected =
        item.ids.every(_selectedIds.contains) && item.ids.isNotEmpty;
    final spec = _notificationSpec(item.type);
    final currentUser = FirebaseAuth.instance.currentUser;

    return GestureDetector(
      onLongPress: () {
        HapticFeedback.selectionClick();
        setState(() {
          for (final id in item.ids) {
            _selectedIds.add(id);
          }
        });
      },
      onTap: () async {
        if (_selectionMode) {
          setState(() {
            if (selected) {
              _selectedIds.removeAll(item.ids);
            } else {
              _selectedIds.addAll(item.ids);
            }
          });
          return;
        }
        HapticFeedback.selectionClick();
        await _openNotificationTarget(item);
      },
      child: Container(
        decoration: BoxDecoration(
          color: selected
              ? selectedColor
              : item.isUnread
                  ? AppColors.primary.withValues(alpha: 0.07)
                  : Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest
                      .withValues(alpha: 0.28),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: item.isUnread
                ? AppColors.primary.withValues(alpha: 0.22)
                : Colors.transparent,
          ),
          boxShadow: [
            BoxShadow(
              color: isDark
                  ? Colors.black.withValues(alpha: 0.18)
                  : Colors.black.withValues(alpha: 0.04),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  CircleAvatar(
                    radius: 26,
                    backgroundColor: AppColors.primary,
                    backgroundImage: item.fromImage != null
                        ? NetworkImage(item.fromImage!)
                        : null,
                    child: item.fromImage == null
                        ? Text(
                            item.fromName.isNotEmpty
                                ? item.fromName[0].toUpperCase()
                                : '?',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          )
                        : null,
                  ),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: spec.color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          width: 2,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        spec.emoji,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: RichText(
                            text: TextSpan(
                              style: Theme.of(context).textTheme.bodyLarge,
                              children: [
                                TextSpan(
                                  text: item.fromName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                TextSpan(
                                  text: _notificationTitle(item),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Text(
                          _formatTime(item.createdAt),
                          style: const TextStyle(
                            color: AppColors.grey,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if ((item.preview ?? '').trim().isNotEmpty)
                      Text(
                        item.preview!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.grey,
                          height: 1.35,
                        ),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        _NotificationPill(
                          icon: spec.icon,
                          label: spec.label,
                          color: spec.color,
                        ),
                        if (item.count > 1) ...[
                          const SizedBox(width: 8),
                          _NotificationPill(
                            icon: Icons.layers_rounded,
                            label: '${item.count}x',
                            color: AppColors.primary,
                          ),
                        ],
                        if (item.type == 'follow' &&
                            currentUser != null &&
                            item.fromUserId.isNotEmpty &&
                            item.fromUserId != currentUser.uid) ...[
                          const SizedBox(width: 8),
                          StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                            stream: FirebaseFirestore.instance
                                .collection('user_follows')
                                .doc('${currentUser.uid}_${item.fromUserId}')
                                .snapshots(),
                            builder: (context, snap) {
                              final isFollowingBack = snap.data?.exists == true;
                              if (isFollowingBack) {
                                return _NotificationPill(
                                  icon: Icons.check_rounded,
                                  label: tr('Following'),
                                  color: const Color(0xFF37C58A),
                                );
                              }
                              return TextButton(
                                onPressed: () async {
                                  HapticFeedback.lightImpact();
                                  await FirebaseFirestore.instance
                                      .collection('user_follows')
                                      .doc(
                                          '${currentUser.uid}_${item.fromUserId}')
                                      .set({
                                    'followerId': currentUser.uid,
                                    'followingId': item.fromUserId,
                                    'createdAt': FieldValue.serverTimestamp(),
                                  });
                                },
                                style: TextButton.styleFrom(
                                  minimumSize: Size.zero,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  backgroundColor:
                                      AppColors.primary.withValues(alpha: 0.10),
                                  foregroundColor: AppColors.primary,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                ),
                                child: Text(
                                  tr('Follow back'),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                        const Spacer(),
                        if (item.isUnread)
                          Container(
                            width: 10,
                            height: 10,
                            decoration: const BoxDecoration(
                              color: AppColors.primary,
                              shape: BoxShape.circle,
                            ),
                          ),
                        if (_selectionMode)
                          Checkbox(
                            value: selected,
                            onChanged: (_) {
                              setState(() {
                                if (selected) {
                                  _selectedIds.removeAll(item.ids);
                                } else {
                                  _selectedIds.addAll(item.ids);
                                }
                              });
                            },
                          )
                        else
                          PopupMenuButton<String>(
                            onSelected: (value) async {
                              if (value == 'delete') {
                                final batch =
                                    FirebaseFirestore.instance.batch();
                                for (final id in item.ids) {
                                  batch.delete(
                                    FirebaseFirestore.instance
                                        .collection('notifications')
                                        .doc(id),
                                  );
                                }
                                await batch.commit();
                              }
                            },
                            itemBuilder: (context) => [
                              PopupMenuItem(
                                value: 'delete',
                                child: Text(tr('Delete')),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (item.postId != null &&
                  (item.type == 'like' || item.type == 'comment')) ...[
                const SizedBox(width: 10),
                _PostNotificationThumbnail(postId: item.postId!),
              ],
            ],
          ),
        ),
      ),
    );
  }

  _NotificationSpec _notificationSpec(String type) {
    switch (type) {
      case 'message':
        return _NotificationSpec(
          icon: Icons.chat_bubble_rounded,
          emoji: '\u{1F4AC}',
          label: tr('Message'),
          color: const Color(0xFF4DA3FF),
        );
      case 'message_request':
        return _NotificationSpec(
          icon: Icons.mark_chat_unread_rounded,
          emoji: '\u{1F4E8}',
          label: tr('Request'),
          color: const Color(0xFF9B6BFF),
        );
      case 'comment':
        return _NotificationSpec(
          icon: Icons.mode_comment_rounded,
          emoji: '\u{1F4AD}',
          label: tr('Comment'),
          color: const Color(0xFFFF9B54),
        );
      case 'order':
        return _NotificationSpec(
          icon: Icons.storefront_rounded,
          emoji: '\u{1F6CD}\uFE0F',
          label: tr('Shop'),
          color: const Color(0xFF14B8A6),
        );
      case 'admin':
        return _NotificationSpec(
          icon: Icons.campaign_rounded,
          emoji: '\u{1F4E2}',
          label: tr('Duhuze team'),
          color: const Color(0xFF1D9BF0),
        );
      case 'review':
        return _NotificationSpec(
          icon: Icons.star_rounded,
          emoji: '\u2B50',
          label: tr('Review'),
          color: const Color(0xFFFFB400),
        );
      case 'mention':
        return _NotificationSpec(
          icon: Icons.alternate_email_rounded,
          emoji: '@',
          label: tr('Mention'),
          color: const Color(0xFF1D9BF0),
        );
      case 'team':
        return _NotificationSpec(
          icon: Icons.groups_rounded,
          emoji: '\u{1F91D}',
          label: tr('Page team'),
          color: const Color(0xFF14B8A6),
        );
      case 'billing':
        return _NotificationSpec(
          icon: Icons.receipt_long_rounded,
          emoji: '\u{1F9FE}',
          label: tr('Payment'),
          color: const Color(0xFF22A06B),
        );
      case 'follow':
        return _NotificationSpec(
          icon: Icons.person_add_alt_1_rounded,
          emoji: '\u2728',
          label: tr('Follow'),
          color: const Color(0xFF7B61FF),
        );
      default:
        return _NotificationSpec(
          icon: Icons.favorite_rounded,
          emoji: '\u2764\uFE0F',
          label: tr('Like'),
          color: const Color(0xFFFF5A7A),
        );
    }
  }

  String _notificationTitle(_GroupedNotification item) {
    switch (item.type) {
      case 'message':
        return item.count > 1
            ? ' sent you ${item.count} new messages [Inbox]'
            : ' sent you a new message [Inbox]';
      case 'message_request':
        return item.count > 1
            ? ' sent you ${item.count} messages in a message request [Requests]'
            : ' sent you a message request [Requests]';
      case 'comment':
        return item.count > 1
            ? ' left ${item.count} new comments on your post'
            : ' commented on your post';
      case 'order':
        return ': ${item.preview ?? 'order update'}';
      case 'report':
        return ': ${item.preview ?? 'new report'}';
      case 'admin':
      case 'review':
      case 'billing':
        return ': ${item.preview ?? ''}';
      case 'team':
        return ' ${item.preview ?? 'added you to a page team'}';
      case 'mention':
        return ' mentioned you: ${item.preview ?? ''}';
      case 'follow':
        return item.count > 1
            ? ' and ${item.count - 1} others followed you'
            : ' followed you';
      default:
        return item.count > 1
            ? ' liked ${item.count} of your posts'
            : ' liked your post';
    }
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }
}

enum _NotificationFilter { all, messages, activity, follows }

class _GroupedNotification {
  _GroupedNotification({
    required this.ids,
    required this.groupKey,
    required this.type,
    required this.fromUserId,
    required this.fromName,
    required this.fromImage,
    required this.postId,
    required this.chatId,
    this.businessId,
    required this.preview,
    required this.createdAt,
    required this.count,
    required this.isUnread,
  });

  final List<String> ids;
  final String groupKey;
  final String type;
  final String fromUserId;
  final String fromName;
  final String? fromImage;
  final String? postId;
  final String? chatId;
  final String? businessId;
  String? preview;
  final DateTime createdAt;
  int count;
  bool isUnread;
}

class _PostNotificationThumbnail extends StatelessWidget {
  const _PostNotificationThumbnail({required this.postId});

  final String postId;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: FirebaseFirestore.instance.collection('posts').doc(postId).get(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data();
        final imageUrl = _resolvePreviewImage(data);
        final hasVideo = _hasVideoMedia(data);

        return ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: 56,
            height: 56,
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withValues(alpha: 0.55),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (imageUrl != null)
                  Image.network(
                    imageUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _buildFallback(hasVideo),
                  )
                else
                  _buildFallback(hasVideo),
                if (hasVideo)
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.35),
                        ],
                      ),
                    ),
                  ),
                if (hasVideo)
                  const Center(
                    child: Icon(
                      Icons.play_circle_fill_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFallback(bool hasVideo) {
    return Container(
      decoration: BoxDecoration(
        gradient: hasVideo
            ? const LinearGradient(
                colors: [
                  Color(0xFF1C2432),
                  Color(0xFF31405E),
                ],
              )
            : null,
        color: hasVideo ? null : const Color(0xFF262C36),
      ),
      child: Center(
        child: Icon(
          hasVideo ? Icons.movie_creation_rounded : Icons.photo_rounded,
          color: Colors.white70,
          size: 24,
        ),
      ),
    );
  }

  String? _resolvePreviewImage(Map<String, dynamic>? data) {
    if (data == null) return null;
    final imageUrl = (data['imageUrl'] ?? '').toString().trim();
    if (imageUrl.isNotEmpty) return imageUrl;
    final media = data['media'];
    if (media is List) {
      for (final item in media) {
        if (item is Map) {
          final normalized = item.map((key, value) => MapEntry('$key', value));
          final type = normalized['type']?.toString();
          final thumb = (normalized['thumbnailUrl'] ?? '').toString().trim();
          final url = (normalized['url'] ?? '').toString().trim();
          if (type == 'image' && url.isNotEmpty) {
            return url;
          }
          if (type == 'video' && thumb.isNotEmpty) {
            return thumb;
          }
        }
      }
    }
    return null;
  }

  bool _hasVideoMedia(Map<String, dynamic>? data) {
    if (data == null) return false;
    final videoUrl = (data['videoUrl'] ?? '').toString().trim();
    if (videoUrl.isNotEmpty) return true;
    final media = data['media'];
    if (media is List) {
      for (final item in media) {
        if (item is Map<String, dynamic>) {
          if (item['type']?.toString() == 'video') {
            return true;
          }
        }
      }
    }
    return false;
  }
}

class _NotificationSpec {
  const _NotificationSpec({
    required this.icon,
    required this.emoji,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String emoji;
  final String label;
  final Color color;
}

class _NotificationsHeroCard extends StatelessWidget {
  const _NotificationsHeroCard({required this.total});

  final int total;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.primary.withValues(alpha: 0.18),
            Colors.pinkAccent.withValues(alpha: 0.12),
          ],
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(
              Icons.notifications_active_rounded,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('Duhuze activity'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$total updates waiting for your attention',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NotificationsEmptyState extends StatelessWidget {
  const _NotificationsEmptyState({
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.notifications_none_rounded,
                size: 34,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.grey,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotificationPill extends StatelessWidget {
  const _NotificationPill({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
