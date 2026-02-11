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
            return const Center(child: Text('Business not found'));
          }

          final raw = businessSnapshot.data!.data();
          if (raw == null) {
            return const Center(child: Text('Business not found'));
          }
          final business = raw as Map<String, dynamic>;
          final name = business['name'] ?? 'Business';
          final imageUrl = business['imageUrl'] as String?;
          final description = business['description'] ?? '';
          final category = business['category'] ?? '';
          final phone = business['phone'] ?? '';
          // final email = business['email'] ?? '';
          final mapsLink = business['googleMapsLink'] ?? '';
          final isVerified = business['isVerified'] == true;
          final ownerId = business['ownerId'] ?? '';
          final rating = (business['rating'] ?? 0).toDouble();
          final starCount = rating.round();

          return CustomScrollView(
            slivers: [
              SliverAppBar(
                pinned: true,
                expandedHeight: 200,
                title: const Text(''),
                flexibleSpace: FlexibleSpaceBar(
                  background: Container(
                    padding: const EdgeInsets.fromLTRB(16, 60, 16, 8),
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
                                      final uri = Uri.parse('tel:$phone');
                                      if (await canLaunchUrl(uri)) {
                                        await launchUrl(uri);
                                      }
                                    },
                            ),
                            const SizedBox(width: 10),
                            CircleAvatar(
                              radius: 36,
                              backgroundColor: AppColors.primary,
                              backgroundImage:
                                  imageUrl != null && imageUrl.isNotEmpty
                                      ? CachedNetworkImageProvider(imageUrl)
                                      : null,
                              child: null,
                            ),
                            const SizedBox(width: 10),
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
                          isVerified ? 'Verified business' : 'Not verified',
                          style: TextStyle(
                            color: isVerified ? Colors.green : AppColors.grey,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
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
                                child: post.imageUrl != null
                                    ? CachedNetworkImage(
                                        imageUrl: post.imageUrl!,
                                        fit: BoxFit.cover,
                                      )
                                    : post.videoUrl != null
                                        ? FutureBuilder<Uint8List?>(
                                            future: _getVideoThumbnail(
                                                post.videoUrl!),
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

}
