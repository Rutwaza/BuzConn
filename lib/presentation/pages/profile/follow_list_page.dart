import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/social_notification_service.dart';
import '../../../core/theme/colors.dart';

enum FollowListType { followers, following }

class FollowListPage extends StatelessWidget {
  const FollowListPage({
    super.key,
    required this.userId,
    required this.type,
  });

  final String userId;
  final FollowListType type;

  String get _title => type == FollowListType.followers ? 'Followers' : 'Following';

  Future<void> _followUser(String followerId, String followingId) async {
    final docId = '${followerId}_$followingId';
    await FirebaseFirestore.instance
        .collection('user_follows')
        .doc(docId)
        .set({
      'followerId': followerId,
      'followingId': followingId,
      'createdAt': FieldValue.serverTimestamp(),
    });
    await SocialNotificationService.createFollowNotification(
      followerId: followerId,
      followingId: followingId,
    );
  }

  Future<void> _unfollowUser(String followerId, String followingId) async {
    final docId = '${followerId}_$followingId';
    await FirebaseFirestore.instance
        .collection('user_follows')
        .doc(docId)
        .delete();
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> _followDocStream(
    String followerId,
    String followingId,
  ) {
    final docId = '${followerId}_$followingId';
    return FirebaseFirestore.instance
        .collection('user_follows')
        .doc(docId)
        .snapshots();
  }

  @override
  Widget build(BuildContext context) {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final query = type == FollowListType.followers
        ? FirebaseFirestore.instance
            .collection('user_follows')
            .where('followingId', isEqualTo: userId)
        : FirebaseFirestore.instance
            .collection('user_follows')
            .where('followerId', isEqualTo: userId);

    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: StreamBuilder<QuerySnapshot>(
        stream: query.snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data?.docs ?? [];
          if (docs.isEmpty) {
            return Center(
              child: Text(
                type == FollowListType.followers
                    ? 'No followers yet'
                    : 'Not following anyone yet',
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final data = docs[index].data() as Map<String, dynamic>;
              final otherUserId = type == FollowListType.followers
                  ? (data['followerId'] ?? '').toString()
                  : (data['followingId'] ?? '').toString();
              if (otherUserId.isEmpty) {
                return const SizedBox.shrink();
              }
              return StreamBuilder<DocumentSnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('users')
                    .doc(otherUserId)
                    .snapshots(),
                builder: (context, userSnap) {
                  final userData =
                      userSnap.data?.data() as Map<String, dynamic>? ?? {};
                  final name = (userData['name'] ?? 'User').toString();
                  final imageUrl = userData['imageUrl'] as String?;
                  return InkWell(
                    onTap: () => context.push(AppRoutes.clientProfilePath(otherUserId)),
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF151A24) : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isDark ? Colors.white10 : Colors.black12,
                        ),
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 22,
                            backgroundColor: AppColors.primary,
                            backgroundImage:
                                imageUrl != null ? NetworkImage(imageUrl) : null,
                            child: imageUrl == null
                                ? Text(
                                    name.isNotEmpty
                                        ? name[0].toUpperCase()
                                        : '?',
                                    style: const TextStyle(color: Colors.white),
                                  )
                                : null,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              name,
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (currentUserId != null &&
                              currentUserId != otherUserId)
                            StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                              stream: _followDocStream(currentUserId, otherUserId),
                              builder: (context, followSnap) {
                                final isFollowing =
                                    followSnap.data?.exists == true;
                                return TextButton(
                                  onPressed: () async {
                                    if (isFollowing) {
                                      await _unfollowUser(
                                          currentUserId, otherUserId);
                                    } else {
                                      await _followUser(
                                          currentUserId, otherUserId);
                                    }
                                  },
                                  style: TextButton.styleFrom(
                                    foregroundColor: isFollowing
                                        ? (isDark ? Colors.white70 : AppColors.grey)
                                        : AppColors.primary,
                                  ),
                                  child: Text(
                                    isFollowing ? 'Following' : 'Follow',
                                  ),
                                );
                              },
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
      ),
    );
  }
}
