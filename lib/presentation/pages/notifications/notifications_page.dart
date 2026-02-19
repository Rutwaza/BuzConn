import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
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
  bool _showHidden = false;
  bool get _selectionMode => _selectedIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _markAllRead();
  }

  Future<void> _markAllRead() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('notifications')
          .where('toUserId', isEqualTo: user.uid)
          .where('readAt', isEqualTo: null)
          .get();
      final batch = FirebaseFirestore.instance.batch();
      for (final doc in snap.docs) {
        batch.update(doc.reference, {'readAt': Timestamp.now()});
      }
      await batch.commit();
    } catch (e) {
      debugPrint('Failed to mark notifications read: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to mark notifications read')),
        );
      }
    }
  }

  Future<void> _hideSelected() async {
    final batch = FirebaseFirestore.instance.batch();
    for (final id in _selectedIds) {
      final ref = FirebaseFirestore.instance.collection('notifications').doc(id);
      batch.update(ref, {'hidden': true});
    }
    await batch.commit();
    setState(() {
      _selectedIds.clear();
    });
  }

  Future<void> _deleteSelected() async {
    final batch = FirebaseFirestore.instance.batch();
    for (final id in _selectedIds) {
      final ref = FirebaseFirestore.instance.collection('notifications').doc(id);
      batch.delete(ref);
    }
    await batch.commit();
    setState(() {
      _selectedIds.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Scaffold(body: Center(child: Text('Please sign in.')));
    }
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = theme.cardColor;
    final selectedColor = theme.colorScheme.primary.withOpacity(0.15);
    final titleStyle = theme.textTheme.bodyLarge;
    final subtitleStyle = theme.textTheme.bodySmall?.copyWith(
      color: isDark ? Colors.white70 : AppColors.grey,
    );

    return Scaffold(
      appBar: AppBar(
        title:
            Text(_selectionMode ? 'Selected ${_selectedIds.length}' : 'Notifications'),
        actions: _selectionMode
            ? [
                IconButton(
                  icon: const Icon(Icons.visibility_off),
                  onPressed: _hideSelected,
                  tooltip: 'Hide selected',
                ),
                IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: _deleteSelected,
                  tooltip: 'Delete selected',
                ),
              ]
            : [
                IconButton(
                  icon: Icon(_showHidden ? Icons.visibility_off : Icons.visibility),
                  tooltip: _showHidden ? 'Hide archived' : 'Show archived',
                  onPressed: () {
                    setState(() {
                      _showHidden = !_showHidden;
                    });
                  },
                ),
              ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('notifications')
            .where('toUserId', isEqualTo: user.uid)
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
          final docs = (snapshot.data?.docs ?? [])
              .where((d) {
                final hidden =
                    (d.data() as Map<String, dynamic>)['hidden'] == true;
                return _showHidden ? hidden : !hidden;
              })
              .toList()
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
            return Center(
              child: Text(
                _showHidden ? 'No hidden notifications.' : 'No notifications yet.',
              ),
            );
          }

          return ListView.separated(
            itemCount: docs.length,
            padding: const EdgeInsets.all(12),
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final doc = docs[index];
              final data = doc.data() as Map<String, dynamic>;
              final id = doc.id;
              final type = data['type'] ?? 'activity';
              final fromName = data['fromUserName'] ?? 'Someone';
              final fromImage = data['fromUserImageUrl'] as String?;
              final postId = data['postId'] as String?;
              final chatId = data['chatId'] as String?;
              final preview = data['preview'] as String?;
              final createdAt = data['createdAt'] as Timestamp?;

              String title;
              if (type == 'message') {
                title = 'New message from $fromName';
              } else if (type == 'comment') {
                title = '$fromName commented on your post';
              } else {
                title = '$fromName liked your post';
              }

              final selected = _selectedIds.contains(id);

              return GestureDetector(
                onLongPress: () {
                  setState(() {
                    _selectedIds.add(id);
                  });
                },
                onTap: () async {
                  if (_selectionMode) {
                    setState(() {
                      if (selected) {
                        _selectedIds.remove(id);
                      } else {
                        _selectedIds.add(id);
                      }
                    });
                    return;
                  }
                  if (type == 'message') {
                    if (chatId == null) return;
                    if (!context.mounted) return;
                    context.push(AppRoutes.chatDetailPath(chatId));
                  } else {
                    if (postId == null) return;
                    final postDoc = await FirebaseFirestore.instance
                        .collection('posts')
                        .doc(postId)
                        .get();
                    if (!postDoc.exists) return;
                    final post = Post.fromFirestore(postDoc);
                    if (!context.mounted) return;
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => PostDetailPage(post: post)),
                    );
                  }
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: selected ? selectedColor : cardColor,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: isDark
                            ? Colors.black.withOpacity(0.2)
                            : Colors.black.withOpacity(0.04),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: AppColors.primary,
                      backgroundImage:
                          fromImage != null ? NetworkImage(fromImage) : null,
                      child: fromImage == null
                          ? Text(
                              fromName.isNotEmpty
                                  ? fromName[0].toUpperCase()
                                  : '?',
                              style: const TextStyle(color: Colors.white),
                            )
                          : null,
                    ),
                    title: Text(
                      title,
                      style: titleStyle,
                    ),
                    subtitle: createdAt == null
                        ? null
                        : Text(
                            type == 'message' && preview != null && preview.isNotEmpty
                                ? '$preview • ${_formatTime(createdAt.toDate())}'
                                : _formatTime(createdAt.toDate()),
                            style: subtitleStyle,
                          ),
                    trailing: _selectionMode
                        ? Checkbox(
                            value: selected,
                            onChanged: (_) {
                              setState(() {
                                if (selected) {
                                  _selectedIds.remove(id);
                                } else {
                                  _selectedIds.add(id);
                                }
                              });
                            },
                          )
                        : PopupMenuButton<String>(
                            onSelected: (value) async {
                              if (value == 'hide') {
                                await FirebaseFirestore.instance
                                    .collection('notifications')
                                    .doc(id)
                                    .update({'hidden': true});
                              } else if (value == 'delete') {
                                await FirebaseFirestore.instance
                                    .collection('notifications')
                                    .doc(id)
                                    .delete();
                              }
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: 'hide',
                                child: Text('Hide'),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete'),
                              ),
                            ],
                          ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }
}
