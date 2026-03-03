import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import '../../../core/theme/colors.dart';
import '../feed/post_detail_page.dart';

class AnalyticsPage extends StatelessWidget {
  const AnalyticsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Scaffold(
        body: Center(child: Text('Please sign in.')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Analytics'),
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .snapshots(),
        builder: (context, userSnap) {
          final userData =
              userSnap.data?.data() as Map<String, dynamic>? ?? {};
          final userType = (userData['userType'] ?? 'client').toString();

          return StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('posts')
                .where('ownerId', isEqualTo: user.uid)
                .snapshots(),
            builder: (context, postsSnap) {
              final postDocs = postsSnap.data?.docs ?? [];
              int totalLikes = 0;
              int totalComments = 0;
              final now = DateTime.now();
              final dailyCounts = List<int>.filled(7, 0);
              for (final doc in postDocs) {
                final data = doc.data() as Map<String, dynamic>;
                final likes = (data['likes'] as List?)?.length ?? 0;
                final comments = (data['comments'] as List?)?.length ?? 0;
                totalLikes += likes;
                totalComments += comments;
                final createdAt = data['createdAt'] as Timestamp?;
                if (createdAt != null) {
                  final date = createdAt.toDate();
                  final diff = now.difference(DateTime(date.year, date.month, date.day)).inDays;
                  if (diff >= 0 && diff < 7) {
                    dailyCounts[6 - diff] += 1;
                  }
                }
              }

              return StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('users')
                    .doc(user.uid)
                    .collection('favorites')
                    .snapshots(),
                builder: (context, favSnap) {
                  final favoritesCount = favSnap.data?.docs.length ?? 0;

                  return StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('chats')
                        .where('participants', arrayContains: user.uid)
                        .snapshots(),
                    builder: (context, chatsSnap) {
                      final chatDocs = chatsSnap.data?.docs ?? [];
                      int unread = 0;
                      for (final doc in chatDocs) {
                        final data = doc.data() as Map<String, dynamic>;
                        final lastMessageAt =
                            data['lastMessageAt'] as Timestamp?;
                        final lastMessageSenderId =
                            data['lastMessageSenderId'] as String?;
                        final lastReadAt =
                            data['lastReadAt'] as Map<String, dynamic>? ?? {};
                        final lastReadForUser =
                            lastReadAt[user.uid] as Timestamp?;
                        final isUnread = lastMessageAt != null &&
                            (lastReadForUser == null ||
                                lastMessageAt
                                    .toDate()
                                    .isAfter(lastReadForUser.toDate()));
                        if (isUnread && lastMessageSenderId != user.uid) {
                          unread++;
                        }
                      }

                      return StreamBuilder<QuerySnapshot>(
                        stream: FirebaseFirestore.instance
                            .collection('notifications')
                            .where('toUserId', isEqualTo: user.uid)
                            .snapshots(),
                        builder: (context, notifSnap) {
                          final notifDocs = notifSnap.data?.docs ?? [];
                          final unreadNotifs = notifDocs.where((doc) {
                            final data = doc.data() as Map<String, dynamic>;
                            return data['readAt'] == null &&
                                data['hidden'] != true;
                          }).length;

                          final cards = <Widget>[
                            _StatCard(
                              title: 'Saved Posts',
                              value: favoritesCount.toString(),
                              icon: Icons.bookmark,
                            ),
                            _StatCard(
                              title: 'Chats',
                              value: chatDocs.length.toString(),
                              icon: Icons.chat_bubble_outline,
                              subtitle:
                                  unread > 0 ? '$unread unread' : 'All read',
                            ),
                            _StatCard(
                              title: 'Notifications',
                              value: unreadNotifs.toString(),
                              icon: Icons.notifications_none,
                              subtitle:
                                  unreadNotifs > 0 ? 'New' : 'All caught up',
                            ),
                          ];

                          if (userType == 'business') {
                            cards.insertAll(0, [
                              _StatCard(
                                title: 'Posts',
                                value: postDocs.length.toString(),
                                icon: Icons.article_outlined,
                                footer: _MiniSparkline(values: dailyCounts),
                              ),
                              _StatCard(
                                title: 'Likes',
                                value: totalLikes.toString(),
                                icon: Icons.star_border,
                                footer: _ProgressLine(
                                  value: totalLikes,
                                  target: 1000,
                                  color: Colors.amber,
                                  label: 'Target 1k',
                                ),
                              ),
                              _StatCard(
                                title: 'Comments',
                                value: totalComments.toString(),
                                icon: Icons.comment_outlined,
                                footer: _ProgressLine(
                                  value: totalComments,
                                  target: 500,
                                  color: Colors.lightBlueAccent,
                                  label: 'Target 500',
                                ),
                              ),
                            ]);
                          }

                          return DefaultTabController(
                            length: 2,
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Overview',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(
                                            fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 12),
                                  GridView.count(
                                    crossAxisCount: 2,
                                    mainAxisSpacing: 12,
                                    crossAxisSpacing: 12,
                                    childAspectRatio: 1.4,
                                    shrinkWrap: true,
                                    physics:
                                        const NeverScrollableScrollPhysics(),
                                    children: cards,
                                  ),
                                  const SizedBox(height: 24),
                                  Text(
                                    'Posts',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(
                                            fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 12),
                                  Container(
                                    decoration: BoxDecoration(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .surface,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: Theme.of(context)
                                                .brightness ==
                                            Brightness.dark
                                            ? Colors.white10
                                            : Colors.black12,
                                      ),
                                    ),
                                    child: const TabBar(
                                      indicatorSize:
                                          TabBarIndicatorSize.tab,
                                      tabs: [
                                        Tab(text: 'Recent Posts'),
                                        Tab(text: 'Saved Posts'),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  SizedBox(
                                    height: 420,
                                    child: TabBarView(
                                      children: [
                                        _RecentPostsList(
                                          postDocs: postDocs,
                                        ),
                                        _SavedPostsList(
                                          favoriteDocs:
                                              favSnap.data?.docs ?? [],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.title,
    required this.value,
    required this.icon,
    this.subtitle,
    this.footer,
  });

  final String title;
  final String value;
  final IconData icon;
  final String? subtitle;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171B24) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? Colors.white10 : Colors.black12,
        ),
        boxShadow: [
          if (!isDark)
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 10,
              offset: const Offset(0, 6),
            ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: AppColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: TextStyle(
                color: isDark ? Colors.white70 : AppColors.grey,
                fontSize: 12,
              ),
            ),
          ],
          if (footer != null) ...[
            const SizedBox(height: 6),
            footer!,
          ],
        ],
      ),
    );
  }
}

class _RecentPostsList extends StatelessWidget {
  const _RecentPostsList({required this.postDocs});

  final List<QueryDocumentSnapshot> postDocs;

  @override
  Widget build(BuildContext context) {
    if (postDocs.isEmpty) {
      return const Center(child: Text('No posts yet.'));
    }

    final sorted = [...postDocs]
      ..sort((a, b) {
        final aData = a.data() as Map<String, dynamic>;
        final bData = b.data() as Map<String, dynamic>;
        final aTs = aData['createdAt'] as Timestamp?;
        final bTs = bData['createdAt'] as Timestamp?;
        return (bTs?.millisecondsSinceEpoch ?? 0)
            .compareTo(aTs?.millisecondsSinceEpoch ?? 0);
      });

    return ListView.separated(
      itemCount: sorted.take(8).length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final data = sorted[index].data() as Map<String, dynamic>;
        return _PostPreviewCard(
          data: data,
          postId: sorted[index].id,
        );
      },
    );
  }
}

class _SavedPostsList extends StatelessWidget {
  const _SavedPostsList({required this.favoriteDocs});

  final List<QueryDocumentSnapshot> favoriteDocs;

  @override
  Widget build(BuildContext context) {
    if (favoriteDocs.isEmpty) {
      return const Center(child: Text('No saved posts.'));
    }

    final ids = favoriteDocs
        .map((doc) {
          final data = doc.data() as Map<String, dynamic>;
          return (data['postId'] ?? doc.id).toString();
        })
        .where((id) => id.isNotEmpty)
        .toList();

    if (ids.isEmpty) {
      return const Center(child: Text('No saved posts.'));
    }

    final limited = ids.take(10).toList();
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('posts')
          .where(FieldPath.documentId, whereIn: limited)
          .snapshots(),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) {
          return const Center(child: Text('No saved posts.'));
        }
        return ListView.separated(
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final data = docs[index].data() as Map<String, dynamic>;
            return _PostPreviewCard(
              data: data,
              postId: docs[index].id,
            );
          },
        );
      },
    );
  }
}

class _PostPreviewCard extends StatelessWidget {
  const _PostPreviewCard({
    required this.data,
    required this.postId,
  });

  final Map<String, dynamic> data;
  final String postId;

  @override
  Widget build(BuildContext context) {
    final content = (data['content'] ?? '').toString();
    final likes = (data['likes'] as List?)?.length ?? 0;
    final comments = (data['comments'] as List?)?.length ?? 0;
    final createdAt = data['createdAt'] as Timestamp?;
    final imageUrl = (data['imageUrl'] ?? '').toString();
    final videoUrl = (data['videoUrl'] ?? '').toString();
    final media = data['media'] as List?;
    String? previewUrl;
    bool isVideo = false;
    if (media != null && media.isNotEmpty) {
      final first = media.first;
      if (first is Map && first['url'] != null) {
        previewUrl = first['url'].toString();
        final type = (first['type'] ?? '').toString().toLowerCase();
        isVideo = type == 'video';
      }
    } else if (imageUrl.isNotEmpty) {
      previewUrl = imageUrl;
    } else if (videoUrl.isNotEmpty) {
      previewUrl = videoUrl;
      isVideo = true;
    }

    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PostDetailPage(postId: postId),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF171B24)
              : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white10
                : Colors.black12,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: AppColors.lightGrey,
                borderRadius: BorderRadius.circular(10),
              ),
              child: previewUrl == null
                  ? const Icon(Icons.image, color: AppColors.grey)
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: isVideo
                          ? _VideoThumb(url: previewUrl)
                          : Image.network(
                              previewUrl,
                              fit: BoxFit.cover,
                            ),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    content.isEmpty ? 'Post' : content,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Likes: $likes  Comments: $comments',
                    style: TextStyle(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.white70
                          : AppColors.grey,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              createdAt == null ? '' : _formatDate(createdAt.toDate()),
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatDate(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '$month/$day';
}

class _MiniSparkline extends StatelessWidget {
  const _MiniSparkline({required this.values});

  final List<int> values;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 28,
      child: CustomPaint(
        painter: _SparklinePainter(
          values: values,
          color: AppColors.primary,
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.values, required this.color});

  final List<int> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final maxVal = values.reduce((a, b) => a > b ? a : b);
    final minVal = values.reduce((a, b) => a < b ? a : b);
    final range = (maxVal - minVal).toDouble();
    final dx = size.width / (values.length - 1).clamp(1, values.length);

    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final v = values[i].toDouble();
      final y = range == 0
          ? size.height * 0.5
          : size.height - ((v - minVal) / range) * size.height;
      final x = i * dx;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) {
    return oldDelegate.values != values || oldDelegate.color != color;
  }
}

class _ProgressLine extends StatelessWidget {
  const _ProgressLine({
    required this.value,
    required this.target,
    required this.color,
    required this.label,
  });

  final int value;
  final int target;
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final progress = (target == 0) ? 0.0 : (value / target).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 6,
          child: LinearProgressIndicator(
            value: progress,
            backgroundColor: Colors.black12,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white70
                : AppColors.grey,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

class _VideoThumb extends StatelessWidget {
  const _VideoThumb({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: VideoThumbnail.thumbnailData(
        video: url,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 240,
        quality: 75,
      ),
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null) {
          return const Center(
            child: Icon(Icons.play_circle_fill, color: Colors.white70),
          );
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            Image.memory(bytes, fit: BoxFit.cover),
            const Center(
              child: Icon(Icons.play_circle_fill, color: Colors.white70),
            ),
          ],
        );
      },
    );
  }
}
