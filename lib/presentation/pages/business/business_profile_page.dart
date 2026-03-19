import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/colors.dart';
import '../../../data/models/post_model.dart';
import 'post_detail_page.dart';
import '../../../data/repositories/chat_repository.dart';
import '../../../core/constants/app_constants.dart';

class BusinessProfilePage extends StatefulWidget {
  final String businessId;

  const BusinessProfilePage({super.key, required this.businessId});

  @override
  State<BusinessProfilePage> createState() => _BusinessProfilePageState();
}

class _BusinessProfilePageState extends State<BusinessProfilePage> {
  final Map<String, Future<Uint8List?>> _thumbCache = {};

  Future<Uint8List?> _getVideoThumbnail(String url) {
    return _thumbCache.putIfAbsent(
      url,
      () => VideoThumbnail.thumbnailData(
        video: url,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 420,
        quality: 70,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('businesses')
            .doc(widget.businessId)
            .snapshots(),
        builder: (context, businessSnapshot) {
          if (businessSnapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!businessSnapshot.hasData || !businessSnapshot.data!.exists) {
            return const Center(child: Text('Page not found'));
          }

          final raw = businessSnapshot.data!.data();
          if (raw == null) {
            return const Center(child: Text('Page not found'));
          }
          final business = raw as Map<String, dynamic>;
          final name = business['name'] ?? 'Page';
          final imageUrl = business['imageUrl'] as String?;
          final category = business['category'] ?? '';
          final phone = business['phone'] ?? '';
          // final email = business['email'] ?? '';
          final isVerified = business['isVerified'] == true;
          final ownerId = business['ownerId'] ?? '';
          final currentUserId = FirebaseAuth.instance.currentUser?.uid;
          final isOwner = currentUserId == ownerId;

          return CustomScrollView(
            slivers: [
              SliverAppBar(
                pinned: true,
                expandedHeight: 230,
                title: const Text(''),
                flexibleSpace: FlexibleSpaceBar(
                  background: Container(
                    padding: const EdgeInsets.fromLTRB(16, 52, 16, 8),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _circleIconButton(
                              icon: Icons.call,
                              onTap: phone.toString().isEmpty
                                  ? null
                                  : () async {
                                      await _dialPhone(context, phone);
                                    },
                            ),
                            const SizedBox(width: 8),
                            CircleAvatar(
                              radius: 32,
                              backgroundColor: AppColors.primary,
                              backgroundImage:
                                  imageUrl != null && imageUrl.isNotEmpty
                                      ? CachedNetworkImageProvider(imageUrl)
                                      : null,
                              child: null,
                            ),
                            const SizedBox(width: 8),
                            _circleIconButton(
                              icon: Icons.message,
                              onTap: () async {
                                final user = FirebaseAuth.instance.currentUser;
                                if (user == null) return;
                                if (user.uid == ownerId) {
                                  if (!context.mounted) return;
                                  context.push(AppRoutes.chats);
                                  return;
                                }
                                final repo = ChatRepository();
                                final chatId = await repo.createOrGetChat(
                                  businessId: widget.businessId,
                                  businessOwnerId: ownerId,
                                  clientId: user.uid,
                                );
                                if (!context.mounted) return;
                                context.push(AppRoutes.chatDetailPath(chatId));
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              name,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 6),
                            if (isVerified)
                              const Icon(Icons.verified,
                                  color: Colors.green, size: 16),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          isVerified ? 'Verified page' : 'Not verified',
                          style: TextStyle(
                            color: isVerified ? Colors.green : AppColors.grey,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        StreamBuilder<QuerySnapshot>(
                          stream: _pageFollowers(widget.businessId),
                          builder: (context, followersSnap) {
                            final followersCount =
                                followersSnap.data?.docs.length ?? 0;
                            return Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 10,
                              runSpacing: 6,
                              children: [
                                _StatPill(
                                  label: 'Followers',
                                  value: followersCount,
                                ),
                                if (!isOwner && currentUserId != null) ...[
                                  StreamBuilder<
                                      DocumentSnapshot<Map<String, dynamic>>>(
                                    stream: _pageFollowDoc(
                                      currentUserId,
                                      widget.businessId,
                                    ),
                                    builder: (context, followSnap) {
                                      final isFollowing =
                                          followSnap.data?.exists == true;
                                      return ElevatedButton(
                                        onPressed: () async {
                                          if (isFollowing) {
                                            await _unfollowPage(
                                              currentUserId,
                                              widget.businessId,
                                            );
                                          } else {
                                            await _followPage(
                                              currentUserId,
                                              widget.businessId,
                                            );
                                          }
                                        },
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: isFollowing
                                              ? Colors.transparent
                                              : AppColors.primary,
                                          foregroundColor: isFollowing
                                              ? AppColors.primary
                                              : Colors.white,
                                          elevation: 0,
                                          side: isFollowing
                                              ? const BorderSide(
                                                  color: AppColors.primary)
                                              : BorderSide.none,
                                          shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(12),
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 6,
                                          ),
                                        ),
                                        child: Text(
                                          isFollowing
                                              ? 'Following'
                                              : 'Follow',
                                        ),
                                      );
                                    },
                                  ),
                                ],
                                if (isOwner) ...[
                                  TextButton(
                                    onPressed: () {
                                      context.push(
                                        AppRoutes.pageFollowersPath(
                                            widget.businessId),
                                      );
                                    },
                                    child: const Text('View'),
                                  ),
                                ],
                              ],
                            );
                          },
                        ),
                        if (category.toString().isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            category,
                            style: const TextStyle(color: AppColors.grey, fontSize: 11),
                          ),
                        ],
                        const SizedBox(height: 6),
                        // Description removed from header to prevent overflow.
                      ],
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('posts')
                      .where('ownerId', isEqualTo: ownerId)
                      .snapshots(),
                  builder: (context, postsSnapshot) {
                    if (postsSnapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final docs = postsSnapshot.data?.docs ?? [];
                    final posts = docs
                        .map((d) => Post.fromFirestore(d))
                        .where((p) =>
                            p.businessId == widget.businessId ||
                            (p.businessId.isEmpty && p.businessName == name))
                        .toList()
                      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

                    if (posts.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: Text('No posts yet')),
                      );
                    }

                    final totalLikes = posts.fold<int>(
                        0, (sum, p) => sum + p.likes.length);
                    final avgLikes =
                        totalLikes / (posts.isEmpty ? 1 : posts.length);

                    return Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.star,
                                  color: Color(0xFFFFD700), size: 16),
                              const SizedBox(width: 4),
                              Text(
                                avgLikes.toStringAsFixed(1),
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(width: 6),
                              const Text(
                                'avg likes',
                                style: TextStyle(color: AppColors.grey),
                              ),
                            ],
                          ),
                        ),
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(8),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 6,
                            mainAxisSpacing: 6,
                          ),
                          itemCount: posts.length,
                          itemBuilder: (context, index) {
                            final post = posts[index];
                            return InkWell(
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => PostDetailPage(post: post),
                                  ),
                                );
                              },
                              child: Container(
                                color: AppColors.lightGrey,
                                child: post.media.isNotEmpty &&
                                        !post.media.first.isVideo
                                    ? CachedNetworkImage(
                                        imageUrl: post.media.first.url,
                                        fit: BoxFit.cover,
                                      )
                                    : post.media.isNotEmpty &&
                                            post.media.first.isVideo
                                        ? FutureBuilder<Uint8List?>(
                                            future: _getVideoThumbnail(
                                                post.media.first.url),
                                            builder: (context, thumbSnap) {
                                              final bytes = thumbSnap.data;
                                              if (bytes == null) {
                                                return const Center(
                                                  child: Icon(
                                                    Icons.play_circle_fill,
                                                    color: Colors.white70,
                                                    size: 32,
                                                  ),
                                                );
                                              }
                                              return Stack(
                                                fit: StackFit.expand,
                                                children: [
                                                  Image.memory(bytes,
                                                      fit: BoxFit.cover),
                                                  const Center(
                                                    child: Icon(
                                                      Icons.play_circle_fill,
                                                      color: Colors.white70,
                                                      size: 32,
                                                    ),
                                                  ),
                                                ],
                                              );
                                            },
                                          )
                                        : const Icon(Icons.text_snippet_outlined),
                              ),
                            );
                          },
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _circleIconButton({
    required IconData icon,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Opacity(
        opacity: onTap == null ? 0.4 : 1,
        child: CircleAvatar(
          radius: 18,
          backgroundColor: AppColors.lightGrey,
          child: Icon(icon, size: 18, color: AppColors.primary),
        ),
      ),
    );
  }

  Future<void> _followPage(String followerId, String pageId) async {
    final docId = '${followerId}_$pageId';
    await FirebaseFirestore.instance
        .collection('page_follows')
        .doc(docId)
        .set({
      'followerId': followerId,
      'pageId': pageId,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _unfollowPage(String followerId, String pageId) async {
    final docId = '${followerId}_$pageId';
    await FirebaseFirestore.instance
        .collection('page_follows')
        .doc(docId)
        .delete();
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> _pageFollowDoc(
      String followerId, String pageId) {
    final docId = '${followerId}_$pageId';
    return FirebaseFirestore.instance
        .collection('page_follows')
        .doc(docId)
        .snapshots();
  }

  Stream<QuerySnapshot> _pageFollowers(String pageId) {
    return FirebaseFirestore.instance
        .collection('page_follows')
        .where('pageId', isEqualTo: pageId)
        .snapshots();
  }

  Future<void> _dialPhone(BuildContext context, String phone) async {
    final trimmed = phone.trim();
    if (trimmed.isEmpty) return;
    final normalized = trimmed.replaceAll(RegExp(r'\s+'), '');
    final uri = Uri(scheme: 'tel', path: normalized);
    final ok = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open dialer.')),
      );
    }
  }

}

class _StatPill extends StatelessWidget {
  const _StatPill({
    required this.label,
    required this.value,
  });

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : Colors.black.withOpacity(0.04),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: isDark ? Colors.white12 : Colors.black12,
        ),
      ),
      child: Column(
        children: [
          Text(
            value.toString(),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              color: AppColors.grey,
            ),
          ),
        ],
      ),
    );
  }
}
