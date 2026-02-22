import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'dart:typed_data';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/colors.dart';
import '../../../data/models/post_model.dart';
import '../../../data/repositories/posts_repository.dart';
import '../../../data/repositories/chat_repository.dart';
import '../../../core/services/supabase_storage_service.dart';

class PostsFeedPage extends ConsumerStatefulWidget {
  const PostsFeedPage({super.key, this.initialPostId});

  final String? initialPostId;

  @override
  ConsumerState<PostsFeedPage> createState() => _PostsFeedPageState();
}

class _PostsFeedPageState extends ConsumerState<PostsFeedPage> {
  final PostsRepository _postsRepository = PostsRepository();
  final TextEditingController _commentController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  String? _commentingOnPostId;
  bool _markingNotifications = false;
  final ValueNotifier<Timestamp?> _badgeClearedAt =
      ValueNotifier<Timestamp?>(null);
  bool _didJumpToPost = false;
  String _searchQuery = '';
  String _pendingQuery = '';

  @override
  void dispose() {
    _commentController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    _badgeClearedAt.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _pendingQuery = value;
  }

  void _applySearch([String? value]) {
    final next = (value ?? _pendingQuery).trim();
    if (next == _searchQuery) return;
    setState(() {
      _searchQuery = next;
    });
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

  Future<void> _markNotificationsRead() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _markingNotifications) return;
    _markingNotifications = true;
    _badgeClearedAt.value = Timestamp.now();
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .update({'lastSeenNotificationsAt': Timestamp.now()});

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
    } catch (e) {
      debugPrint('Failed to mark notifications read: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to mark notifications read')),
        );
      }
    } finally {
      _markingNotifications = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trends'),
        leading: IconButton(
          icon: const Icon(Icons.home),
          onPressed: () {
            context.push(AppRoutes.dashboard);
          },
        ),
        actions: [
          ValueListenableBuilder<Timestamp?>(
            valueListenable: _badgeClearedAt,
            builder: (context, clearedAt, _) {
              return StreamBuilder<DocumentSnapshot>(
                stream: currentUser == null
                    ? const Stream.empty()
                    : FirebaseFirestore.instance
                        .collection('users')
                        .doc(currentUser.uid)
                        .snapshots(),
                builder: (context, userSnap) {
                  final userData =
                      userSnap.data?.data() as Map<String, dynamic>?;
                  final lastSeen =
                      userData?['lastSeenNotificationsAt'] as Timestamp?;
                  final effectiveClearedAt = clearedAt ?? lastSeen;
                  return StreamBuilder<QuerySnapshot>(
                    stream: currentUser == null
                        ? const Stream.empty()
                        : FirebaseFirestore.instance
                            .collection('notifications')
                            .where('toUserId', isEqualTo: currentUser.uid)
                            .where('readAt', isEqualTo: null)
                            .snapshots(),
                    builder: (context, notifSnap) {
                      final docs = notifSnap.data?.docs ?? [];
                      final count = docs.where((d) {
                        final data = d.data() as Map<String, dynamic>;
                        if (data['hidden'] == true) return false;
                        if (effectiveClearedAt == null) return true;
                        final createdAt = data['createdAt'] as Timestamp?;
                        if (createdAt == null) return true;
                        return createdAt.compareTo(effectiveClearedAt) > 0;
                      }).length;
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
                  );
                },
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
          final query = _searchQuery.trim().toLowerCase();
          final filtered = query.isEmpty
              ? posts
              : posts.where((post) {
                  final name = post.businessName.toLowerCase();
                  final content = post.content.toLowerCase();
                  return name.contains(query) || content.contains(query);
                }).toList();

          final likedBusinesses = <String, Post>{};
          if (currentUser != null) {
            for (final post in posts) {
              if (post.likes.contains(currentUser.uid) &&
                  !likedBusinesses.containsKey(post.businessId)) {
                likedBusinesses[post.businessId] = post;
                if (likedBusinesses.length >= 5) break;
              }
            }
          }
          final likedList = likedBusinesses.values.toList();

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

          final postKeys = <String, GlobalObjectKey>{};
          return Column(
            children: [
              if (likedList.isNotEmpty)
                SizedBox(
                  height: 100,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    scrollDirection: Axis.horizontal,
                    itemCount: likedList.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 12),
                    itemBuilder: (context, index) {
                      final post = likedList[index];
                      return InkWell(
                        onTap: () {
                          final key = postKeys[post.id];
                          final ctx = key?.currentContext;
                          if (ctx != null) {
                            Scrollable.ensureVisible(
                              ctx,
                              duration: const Duration(milliseconds: 300),
                              alignment: 0.1,
                            );
                          }
                        },
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            CircleAvatar(
                              radius: 24,
                              backgroundColor: AppColors.primary,
                              backgroundImage: post.businessImageUrl != null &&
                                      post.businessImageUrl!.isNotEmpty
                                  ? CachedNetworkImageProvider(
                                      post.businessImageUrl!)
                                  : null,
                              child: (post.businessImageUrl == null ||
                                      post.businessImageUrl!.isEmpty)
                                  ? Text(
                                      post.businessName.isNotEmpty
                                          ? post.businessName[0].toUpperCase()
                                          : '?',
                                      style:
                                          const TextStyle(color: Colors.white),
                                    )
                                  : null,
                            ),
                            const SizedBox(height: 6),
                            SizedBox(
                              width: 72,
                              height: 14,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  post.businessName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontSize: 10),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: TextField(
                  controller: _searchController,
                  onChanged: _onSearchChanged,
                  onSubmitted: _applySearch,
                  decoration: InputDecoration(
                    hintText: 'Search businesses or descriptions...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _searchController,
                      builder: (context, value, _) {
                        final hasText = value.text.trim().isNotEmpty;
                        if (!hasText) return const SizedBox.shrink();
                        return SizedBox(
                          width: 96,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.search),
                                onPressed: () => _applySearch(value.text),
                              ),
                              IconButton(
                                icon: const Icon(Icons.close),
                                onPressed: () {
                                  _searchController.clear();
                                  _applySearch('');
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Text(
                          query.isNotEmpty
                              ? 'No results for \"$query\"'
                              : 'No posts yet',
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final post = filtered[index];
              final key = postKeys.putIfAbsent(
                post.id,
                () => GlobalObjectKey(post.id),
              );
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!_didJumpToPost &&
                    widget.initialPostId != null &&
                    post.id == widget.initialPostId) {
                  _didJumpToPost = true;
                  final ctx = key.currentContext;
                  if (ctx != null) {
                    Scrollable.ensureVisible(
                      ctx,
                      duration: const Duration(milliseconds: 300),
                      alignment: 0.1,
                    );
                  }
                }
              });

              return StreamBuilder<DocumentSnapshot>(
                stream: currentUser == null
                    ? const Stream.empty()
                    : FirebaseFirestore.instance
                        .collection('users')
                        .doc(currentUser.uid)
                        .collection('favorites')
                        .doc(post.id)
                        .snapshots(),
                builder: (context, favSnap) {
                  final isSaved = favSnap.data?.exists == true;
                  return PostCard(
                    key: key,
                    post: post,
                    currentUserId: currentUser?.uid ?? '',
                    isSaved: isSaved,
                    onLike: () => _postsRepository.toggleLike(post.id),
                    onComment: () => _showCommentDialog(post.id),
                    onShare: () => _sharePost(post),
                    onLocationTap: () => _openLocation(post),
                    onMessage: () => _startChat(post),
                    onSave: () => _toggleFavorite(post, isSaved),
                    onEdit: () => _showEditDialog(post),
                    onDelete: () => _confirmDelete(post),
                  );
                },
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

  void _showEditDialog(Post post) {
    final controller = TextEditingController(text: post.content);
    File? pickedImage;
    File? pickedVideo;
    bool removeMedia = false;
    bool pickingMedia = false;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocalState) => AlertDialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          titlePadding: const EdgeInsets.only(top: 12),
          title: const Center(child: Text('Edit Post')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    hintText: 'Update your post...',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 4,
                  maxLength: 300,
                ),
                const SizedBox(height: 12),
                if (!removeMedia &&
                    pickedImage == null &&
                    pickedVideo == null &&
                    post.imageUrl != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImage(
                      imageUrl: post.imageUrl!,
                      height: 140,
                      width: double.infinity,
                      fit: BoxFit.cover,
                    ),
                  ),
                if (!removeMedia &&
                    pickedImage == null &&
                    pickedVideo == null &&
                    post.videoUrl != null)
                  Container(
                    height: 140,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.lightGrey,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.videocam, size: 36),
                  ),
                if (pickedImage != null)
                  Container(
                    height: 140,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      image: DecorationImage(
                        image: FileImage(pickedImage!),
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                if (pickedVideo != null)
                  Container(
                    height: 140,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.lightGrey,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.videocam, size: 36),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextButton.icon(
                        onPressed: pickingMedia
                            ? null
                            : () async {
                                setLocalState(() => pickingMedia = true);
                                final picker = ImagePicker();
                                final picked = await picker.pickImage(
                                    source: ImageSource.gallery);
                                if (picked != null) {
                                  setLocalState(() {
                                    pickedImage = File(picked.path);
                                    pickedVideo = null;
                                    removeMedia = false;
                                  });
                                }
                                setLocalState(() => pickingMedia = false);
                              },
                        icon: const Icon(Icons.photo),
                        label: const Text('Pick image'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextButton.icon(
                        onPressed: pickingMedia
                            ? null
                            : () async {
                                setLocalState(() => pickingMedia = true);
                                final picker = ImagePicker();
                                final picked = await picker.pickImage(
                                    source: ImageSource.camera);
                                if (picked != null) {
                                  setLocalState(() {
                                    pickedImage = File(picked.path);
                                    pickedVideo = null;
                                    removeMedia = false;
                                  });
                                }
                                setLocalState(() => pickingMedia = false);
                              },
                        icon: const Icon(Icons.photo_camera),
                        label: const Text('Take photo'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextButton.icon(
                        onPressed: pickingMedia
                            ? null
                            : () async {
                                setLocalState(() => pickingMedia = true);
                                final picker = ImagePicker();
                                final picked = await picker.pickVideo(
                                    source: ImageSource.gallery);
                                if (picked != null) {
                                  setLocalState(() {
                                    pickedVideo = File(picked.path);
                                    pickedImage = null;
                                    removeMedia = false;
                                  });
                                }
                                setLocalState(() => pickingMedia = false);
                              },
                        icon: const Icon(Icons.video_library),
                        label: const Text('Pick video'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextButton.icon(
                        onPressed: pickingMedia
                            ? null
                            : () async {
                                setLocalState(() => pickingMedia = true);
                                final picker = ImagePicker();
                                final picked = await picker.pickVideo(
                                    source: ImageSource.camera);
                                if (picked != null) {
                                  setLocalState(() {
                                    pickedVideo = File(picked.path);
                                    pickedImage = null;
                                    removeMedia = false;
                                  });
                                }
                                setLocalState(() => pickingMedia = false);
                              },
                        icon: const Icon(Icons.videocam),
                        label: const Text('Record video'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.center,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      setLocalState(() {
                        pickedImage = null;
                        pickedVideo = null;
                        removeMedia = true;
                      });
                    },
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Remove media'),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final text = controller.text.trim();
                if (text.isEmpty) return;
                String? imageUrl = post.imageUrl;
                String? videoUrl = post.videoUrl;
                if (removeMedia) {
                  imageUrl = null;
                  videoUrl = null;
                } else if (pickedImage != null) {
                  imageUrl = await _uploadImage(pickedImage!);
                  videoUrl = null;
                } else if (pickedVideo != null) {
                  videoUrl = await _uploadVideo(pickedVideo!);
                  imageUrl = null;
                }
                await FirebaseFirestore.instance
                    .collection('posts')
                    .doc(post.id)
                    .update({
                  'content': text,
                  'imageUrl': imageUrl,
                  'videoUrl': videoUrl,
                  'updatedAt': Timestamp.now(),
                });
                if (mounted) {
                  Navigator.of(context).pop();
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
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

  Future<void> _toggleFavorite(Post post, bool isSaved) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final ref = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('favorites')
        .doc(post.id);
    if (isSaved) {
      await ref.delete();
    } else {
      await ref.set({
        'postId': post.id,
        'createdAt': Timestamp.now(),
      });
    }
  }

  Future<String?> _uploadImage(File imageFile) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      final bytes = await imageFile.readAsBytes();
      final path =
          '${user?.uid ?? 'anon'}/${DateTime.now().millisecondsSinceEpoch}.jpg';
      return await SupabaseStorageService.instance.uploadImage(
        bucket: 'post-images',
        path: path,
        bytes: bytes,
      );
    } catch (e) {
      debugPrint('Error uploading image: $e');
      return null;
    }
  }

  Future<String?> _uploadVideo(File videoFile) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      final bytes = await videoFile.readAsBytes();
      final path =
          '${user?.uid ?? 'anon'}/${DateTime.now().millisecondsSinceEpoch}.mp4';
      return await SupabaseStorageService.instance.uploadVideo(
        bucket: 'post-videos',
        path: path,
        bytes: bytes,
      );
    } catch (e) {
      debugPrint('Error uploading video: $e');
      return null;
    }
  }

  Widget _mediaActionTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool disabled = false,
  }) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(label),
      enabled: !disabled,
      onTap: disabled ? null : onTap,
    );
  }

  Future<void> _startChat(Post post) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    if (user.uid == post.ownerId) {
      if (mounted) {
        context.push(AppRoutes.chats);
      }
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
  final bool isSaved;
  final VoidCallback onSave;
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
    required this.isSaved,
    required this.onSave,
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
                          (post.businessName.isNotEmpty
                                  ? post.businessName[0]
                                  : '?')
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
                          if (post.businessId.isNotEmpty) {
                            context.push(
                                AppRoutes.businessProfilePath(post.businessId));
                          }
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
                if (post.googleMapsLink != null &&
                    post.googleMapsLink!.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.location_on),
                    onPressed: onLocationTap,
                    tooltip: 'Open location',
                  ),
                IconButton(
                  icon: Icon(
                    isSaved ? Icons.bookmark : Icons.bookmark_border,
                    color: isSaved ? AppColors.primary : null,
                    ),
                    onPressed: onSave,
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
