import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../../data/models/post_model.dart';
import '../business/post_detail_page.dart';

class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Scaffold(body: Center(child: Text('Please sign in.')));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: () async {
              await FirebaseFirestore.instance
                  .collection('users')
                  .doc(user.uid)
                  .update({
                'lastNotificationsReadAt': FieldValue.serverTimestamp(),
              });
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Marked as read')),
                );
              }
            },
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('posts')
            .where('ownerId', isEqualTo: user.uid)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snapshot.data?.docs ?? [];
          if (docs.isEmpty) {
            return const Center(child: Text('No notifications yet.'));
          }

          final posts = docs.map(Post.fromFirestore).toList()
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

          return ListView.separated(
            itemCount: posts.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final post = posts[index];
              final likeCount = post.likes.length;
              final commentCount = post.comments.length;
              final subtitleParts = <String>[];
              if (likeCount > 0) subtitleParts.add('$likeCount likes');
              if (commentCount > 0) subtitleParts.add('$commentCount comments');
              final subtitle = subtitleParts.isEmpty
                  ? 'No interactions yet'
                  : subtitleParts.join(' • ');

              return ListTile(
                leading: const Icon(Icons.notifications, color: AppColors.primary),
                title: Text(post.businessName.isNotEmpty
                    ? post.businessName
                    : 'Your post'),
                subtitle: Text(subtitle),
                trailing: Text(
                  _formatTime(post.updatedAt),
                  style: const TextStyle(color: AppColors.grey, fontSize: 12),
                ),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PostDetailPage(post: post),
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

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }
}
