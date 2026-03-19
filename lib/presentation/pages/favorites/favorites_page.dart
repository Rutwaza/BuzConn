import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'package:video_thumbnail/video_thumbnail.dart';
import '../../../core/theme/colors.dart';
import '../../../data/models/post_model.dart';
import '../feed/post_detail_page.dart';

class FavoritesPage extends StatelessWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Scaffold(body: Center(child: Text('Please sign in.')));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Saved'),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('favorites')
            .orderBy('createdAt', descending: true)
            .snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data?.docs ?? [];
          if (docs.isEmpty) {
            return const Center(child: Text('No saved posts yet.'));
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final fav = docs[index];
              final postId = fav.id;
              return StreamBuilder<DocumentSnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('posts')
                    .doc(postId)
                    .snapshots(),
                builder: (context, postSnap) {
                  if (postSnap.connectionState == ConnectionState.waiting) {
                    return _loadingCard();
                  }
                  if (!postSnap.hasData || !postSnap.data!.exists) {
                    return _deletedCard(context, postId, user.uid);
                  }
                  final post = Post.fromFirestore(postSnap.data!);
                  return _postCard(context, post, user.uid);
                },
              );
            },
          );
        },
      ),
    );
  }

  Widget _postCard(BuildContext context, Post post, String userId) {
    final media = post.media;
    String? previewUrl;
    bool isVideo = false;
    if (media.isNotEmpty) {
      previewUrl = media.first.url;
      isVideo = media.first.isVideo;
    } else if (post.imageUrl != null && post.imageUrl!.isNotEmpty) {
      previewUrl = post.imageUrl;
    } else if (post.videoUrl != null && post.videoUrl!.isNotEmpty) {
      previewUrl = post.videoUrl;
      isVideo = true;
    }

    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PostDetailPage(postId: post.id),
          ),
        );
      },
      borderRadius: BorderRadius.circular(12),
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
                    post.content.isEmpty ? 'Post' : post.content,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Likes: ${post.likes.length}  Comments: ${post.comments.length}',
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
              _formatDate(post.createdAt),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.bookmark_remove),
              onPressed: () => _unsave(userId, post.id),
            ),
          ],
        ),
      ),
    );
  }

  Widget _deletedCard(BuildContext context, String postId, String userId) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.error_outline, color: AppColors.grey),
        title: const Text('Post deleted'),
        subtitle: const Text('This post is no longer available.'),
        trailing: IconButton(
          icon: const Icon(Icons.delete),
          onPressed: () => _unsave(userId, postId),
        ),
      ),
    );
  }

  Widget _loadingCard() {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Expanded(child: Text('Loading...')),
          ],
        ),
      ),
    );
  }

  Future<void> _unsave(String userId, String postId) async {
    await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .collection('favorites')
        .doc(postId)
        .delete();
  }

  String _formatDate(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$month/$day';
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
