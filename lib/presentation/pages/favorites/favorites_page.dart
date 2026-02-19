import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/colors.dart';
import '../../../data/models/post_model.dart';

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
        title: const Text('Favorites'),
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
    return InkWell(
      onTap: () {
        context.push('${AppRoutes.feed}?postId=${post.id}');
      },
      borderRadius: BorderRadius.circular(12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: AppColors.primary,
                child: Text(
                  (post.businessName.isNotEmpty ? post.businessName[0] : '?')
                      .toUpperCase(),
                  style: const TextStyle(color: Colors.white),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      post.businessName,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      post.content,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.bookmark_remove),
                onPressed: () => _unsave(userId, post.id),
              ),
            ],
          ),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: const [
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
}
