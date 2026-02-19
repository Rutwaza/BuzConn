import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'dart:typed_data';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/colors.dart';
import '../../../data/models/post_model.dart';
import '../../../data/repositories/posts_repository.dart';
import '../../../data/repositories/chat_repository.dart';

class PostsFeedPage extends ConsumerStatefulWidget {
  const PostsFeedPage({super.key});

  @override
  ConsumerState<PostsFeedPage> createState() => _PostsFeedPageState();
}

class _PostsFeedPageState extends ConsumerState<PostsFeedPage> {
  final PostsRepository _postsRepository = PostsRepository();
  final TextEditingController _commentController = TextEditingController();
  String? _commentingOnPostId;
  bool _markingNotifications = false;

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  void _showCommentDialog(String postId) {
    setState(() {
      _commentingOnPostId = postId;
    });

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Comment'),
        content: TextField(
          controller: _commentController,
          decoration: const InputDecoration(
            hintText: 'Write a comment...',
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _commentController.clear();
              setState(() {
                _commentingOnPostId = null;
              });
            },
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (_commentController.text.trim().isNotEmpty) {
                await _postsRepository.addComment(
                  postId,
                  _commentController.text.trim(),
                );
                Navigator.of(context).pop();
                _commentController.clear();
                setState(() {
                  _commentingOnPostId = null;
                });
              }
            },
            child: const Text('Comment'),
          ),
        ],
      ),
    );
  }

  void _showEditDialog(Post post) {
    final controller = TextEditingController(text: post.content);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Post'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'Update your post...',
            border: OutlineInputBorder(),
          ),
          maxLines: 4,
          maxLength: 300,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final text = controller.text.trim();
              if (text.isEmpty) return;
              await _postsRepository.updatePostContent(
                postId: post.id,
                content: text,
              );
              if (mounted) {
                Navigator.of(context).pop();
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(Post post) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Post'),
        content: const Text('Are you sure you want to delete this post?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              await _postsRepository.deletePost(post.id);
              if (mounted) {
                Navigator.of(context).pop();
              }
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _markNotificationsRead() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _markingNotifications) return;
    _markingNotifications = true;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('notifications')
          .where('toUserId', isEqualTo: user.uid)
          .where('readAt', isEqualTo: null)
          .get();
      if (snap.docs.isEmpty) return;
      final batch = FirebaseFirestore.instance.batch();
      for (final doc in snap.docs) {
        batch.update(doc.reference, {'readAt': Timestamp.now()});
      }
      await batch.commit();
    } finally {
      _markingNotifications = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Business Feed'),
        leading: IconButton(
          icon: const Icon(Icons.home),
          onPressed: () {
            context.push(AppRoutes.dashboard);
          },
        ),
        actions: [
          StreamBuilder<QuerySnapshot>(
            stream: currentUser == null
                ? const Stream.empty()
                : FirebaseFirestore.instance
                    .collection('notifications')
                    .where('toUserId', isEqualTo: currentUser.uid)
                    .where('readAt', isEqualTo: null)
                    .snapshots(),
            builder: (context, notifSnap) {
              final docs = notifSnap.data?.docs ?? [];
              final count = docs
                  .where(
                      (d) => (d.data() as Map<String, dynamic>)['hidden'] != true)
                  .length;
              return IconButton(
                onPressed: () async {
                  await _markNotificationsRead();
                  context.push(AppRoutes.notifications);
                },
                icon: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Icon(Icons.notifications),
                    if (count > 0)
                      Positioned(
                        right: -6,
                        top: -6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            count.toString(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () {
              context.push(AppRoutes.createPost);
            },
          ),
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () {
              context.push(AppRoutes.profile);
            },
          ),
        ],
      ),
      body: StreamBuilder<List<Post>>(
        stream: _postsRepository.getPosts(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Text('Error: ${snapshot.error}'),
            );
          }

          final posts = snapshot.data ?? [];

          if (posts.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.post_add,
                    size: 64,
                    color: AppColors.grey,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No posts yet',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Follow businesses to see their posts here',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.grey,
                    ),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            itemCount: posts.length,
            itemBuilder: (context, index) {
              final post = posts[index];
              return PostCard(
                post: post,
                currentUserId: currentUser?.uid ?? '',
                onLike: () => _postsRepository.toggleLike(post.id),
                onComment: () => _showCommentDialog(post.id),
                onShare: () => _sharePost(post),
                onLocationTap: () => _openLocation(post),
                onMessage: () => _startChat(post),
                onEdit: () => _showEditDialog(post),
                onDelete: () => _confirmDelete(post),
              );
            },
          );
        },
      ),
    );
  }

  void _sharePost(Post post) {
    // For now, just show a snackbar. In a real app, you'd implement sharing
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Share feature coming soon!')),
    );
  }

  void _openLocation(Post post) async {
    if (post.googleMapsLink != null && post.googleMapsLink!.isNotEmpty) {
      final Uri url = Uri.parse(post.googleMapsLink!);
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open Google Maps')),
        );
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Location not available')),
      );
    }
  }

  Future<void> _startChat(Post post) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    if (user.uid == post.ownerId) {
      context.push(AppRoutes.chats);
      return;
    }

    final repo = ChatRepository();
    final chatId = await repo.createOrGetChat(
      businessId: post.businessId,
      businessOwnerId: post.ownerId,
      clientId: user.uid,
    );
    if (!mounted) return;
    context.push(AppRoutes.chatDetailPath(chatId));
  }
}

class PostCard extends StatelessWidget {
  final Post post;
  final String currentUserId;
  final VoidCallback onLike;
  final VoidCallback onComment;
  final VoidCallback onShare;
  final VoidCallback onLocationTap;
  final VoidCallback onMessage;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const PostCard({
    super.key,
    required this.post,
    required this.currentUserId,
    required this.onLike,
    required this.onComment,
    required this.onShare,
    required this.onLocationTap,
    required this.onMessage,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isLiked = post.likes.contains(currentUserId);
    final timeAgo = _formatTimeAgo(post.createdAt);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Business header
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: AppColors.primary,
                  backgroundImage: (post.businessImageUrl != null &&
                          post.businessImageUrl!.isNotEmpty)
                      ? CachedNetworkImageProvider(post.businessImageUrl!)
                      : null,
                  child: (post.businessImageUrl == null ||
                          post.businessImageUrl!.isEmpty)
                      ? Text(
                          (post.businessName.isNotEmpty ? post.businessName[0] : '?')
                              .toUpperCase(),
                          style: const TextStyle(color: Colors.white),
                        )
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GestureDetector(
                        onTap: () {
                          context.push(AppRoutes.businessProfilePath(post.businessId));
                        },
                        child: Text(
                          post.businessName.isNotEmpty
                              ? post.businessName
                              : 'Unknown Business',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      Text(
                        timeAgo,
                        style: const TextStyle(
                          color: AppColors.grey,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.message),
                  onPressed: onMessage,
                  tooltip: 'Message business',
                ),
                if (post.ownerId == currentUserId)
                  PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'edit') {
                        onEdit();
                      } else if (value == 'delete') {
                        onDelete();
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'edit',
                        child: Text('Edit'),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete'),
                      ),
                    ],
                  ),
              ],
            ),

            const SizedBox(height: 12),

            // Post content
            Text(
              post.content,
              style: const TextStyle(fontSize: 16),
            ),

            // Post image
            if (post.imageUrl != null) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
                  imageUrl: post.imageUrl!,
                  height: 200,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  placeholder: (context, url) => Container(
                    height: 200,
                    color: AppColors.lightGrey,
                    child: const Center(child: CircularProgressIndicator()),
                  ),
                  errorWidget: (context, url, error) => Container(
                    height: 200,
                    color: AppColors.lightGrey,
                    child: const Icon(Icons.error),
                  ),
                ),
              ),
            ],

            // Post video
            if (post.videoUrl != null) ...[
              const SizedBox(height: 12),
              InlineVideoPlayer(url: post.videoUrl!),
            ],

            const SizedBox(height: 12),

            // Action buttons
            Row(
              children: [
                IconButton(
                  icon: Icon(
                    isLiked ? Icons.star : Icons.star_border,
                    color: isLiked ? Colors.amber : null,
                  ),
                  onPressed: onLike,
                ),
                Text('${post.likes.length}'),
                const SizedBox(width: 16),
                IconButton(
                  icon: const Icon(Icons.comment),
                  onPressed: onComment,
                ),
                Text('${post.comments.length}'),
                const SizedBox(width: 16),
                IconButton(
                  icon: const Icon(Icons.share),
                  onPressed: onShare,
                ),
                const Spacer(),
                if (post.googleMapsLink != null && post.googleMapsLink!.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.location_on),
                    onPressed: onLocationTap,
                  ),
              ],
            ),

            // Comments preview
            if (post.comments.isNotEmpty) ...[
              const Divider(),
              ...post.comments.take(2).map((comment) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${comment.userName}: ',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Expanded(
                      child: Text(comment.content),
                    ),
                  ],
                ),
              )),
              if (post.comments.length > 2)
                Text(
                  'View all ${post.comments.length} comments',
                  style: const TextStyle(
                    color: AppColors.primary,
                    fontSize: 12,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatTimeAgo(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inDays > 0) {
      return '${difference.inDays}d ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m ago';
    } else {
      return 'Just now';
    }
  }
}

class InlineVideoPlayer extends StatefulWidget {
  final String url;

  const InlineVideoPlayer({super.key, required this.url});

  @override
  State<InlineVideoPlayer> createState() => _InlineVideoPlayerState();
}

class _InlineVideoPlayerState extends State<InlineVideoPlayer> {
  VideoPlayerController? _controller;
  Future<Uint8List?>? _thumbFuture;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _thumbFuture = VideoThumbnail.thumbnailData(
      video: widget.url,
      imageFormat: ImageFormat.JPEG,
      maxWidth: 480,
      quality: 70,
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    if (_controller == null) {
      _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
      await _controller!.initialize();
    }
    await _controller!.play();
    if (mounted) {
      setState(() {
        _isPlaying = true;
      });
    }
  }

  Future<void> _pause() async {
    if (_controller == null) return;
    await _controller!.pause();
    if (mounted) {
      setState(() {
        _isPlaying = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 200,
        width: double.infinity,
        color: AppColors.lightGrey,
        child: _isPlaying && _controller != null
            ? Stack(
                alignment: Alignment.center,
                children: [
                  AspectRatio(
                    aspectRatio: _controller!.value.aspectRatio,
                    child: VideoPlayer(_controller!),
                  ),
                  IconButton(
                    icon: const Icon(Icons.pause_circle_filled,
                        color: Colors.white70, size: 48),
                    onPressed: _pause,
                  ),
                ],
              )
            : FutureBuilder<Uint8List?>(
                future: _thumbFuture,
                builder: (context, snapshot) {
                  final bytes = snapshot.data;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      if (bytes != null)
                        Image.memory(bytes, fit: BoxFit.cover)
                      else
                        Container(color: Colors.black45),
                      Center(
                        child: IconButton(
                          icon: const Icon(Icons.play_circle_fill,
                              color: Colors.white70, size: 48),
                          onPressed: _play,
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }
}
