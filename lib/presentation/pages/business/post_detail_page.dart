import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';
import 'package:video_player/video_player.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/colors.dart';
import '../../../data/models/post_model.dart';
import '../../../data/repositories/posts_repository.dart';

class PostDetailPage extends StatefulWidget {
  final Post post;
  final int initialMediaIndex;

  const PostDetailPage({
    super.key,
    required this.post,
    this.initialMediaIndex = 0,
  });

  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends State<PostDetailPage> {
  late final PageController _controller;
  final _commentController = TextEditingController();
  final _repo = PostsRepository();
  final Map<String, String?> _userImageCache = {};
  int _mediaIndex = 0;
  VideoPlayerController? _videoController;
  String? _currentVideoUrl;
  final ValueNotifier<bool> _isMuted = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    _mediaIndex = widget.initialMediaIndex;
    _controller = PageController(initialPage: _mediaIndex);
    if (widget.post.media.isNotEmpty) {
      _handleMediaIndexChange(widget.post.media, _mediaIndex);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _commentController.dispose();
    _videoController?.dispose();
    _isMuted.dispose();
    super.dispose();
  }

  void _initVideo(String url) {
    _videoController?.dispose();
    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    _videoController = controller;
    _currentVideoUrl = url;
    controller.initialize().then((_) {
      if (mounted) {
        setState(() {});
        controller.setVolume(_isMuted.value ? 0 : 1);
        controller.play();
      }
    });
  }

  void _handleMediaIndexChange(List<PostMedia> media, int index) {
    if (media.isEmpty) return;
    final current = media[index.clamp(0, media.length - 1)];
    if (current.isVideo) {
      if (_currentVideoUrl != current.url) {
        _initVideo(current.url);
      }
    } else {
      _videoController?.pause();
      _currentVideoUrl = null;
    }
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Future<void> _toggleFavorite(String postId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final ref = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('favorites')
        .doc(postId);
    final snap = await ref.get();
    if (snap.exists) {
      await ref.delete();
    } else {
      await ref.set({
        'postId': postId,
        'createdAt': Timestamp.now(),
      });
    }
  }

  Future<void> _openLocation(String? link) async {
    if (link == null || link.isEmpty) return;
    final uri = Uri.parse(link);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open Google Maps')),
      );
    }
  }

  Future<void> _addComment(String postId) async {
    final text = _commentController.text.trim();
    if (text.isEmpty) return;
    await _repo.addComment(postId, text);
    _commentController.clear();
  }

  Future<void> _showEditCommentDialog(Comment comment) async {
    final controller = TextEditingController(text: comment.content);
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Edit comment'),
          content: TextField(
            controller: controller,
            maxLines: 4,
            minLines: 1,
            decoration: const InputDecoration(
              hintText: 'Update your comment...',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(
                context,
                controller.text.trim(),
              ),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    final newText = result?.trim();
    if (newText == null || newText.isEmpty || newText == comment.content) {
      return;
    }
    await _repo.updateComment(
      postId: widget.post.id,
      commentId: comment.id,
      newContent: newText,
    );
  }

  Future<void> _confirmDeleteComment(Comment comment) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete comment'),
          content: const Text('Remove this comment for everyone?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (shouldDelete == true) {
      await _repo.deleteComment(
        postId: widget.post.id,
        commentId: comment.id,
      );
    }
  }

  void _showCommentActions(Comment comment) {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null || currentUser.uid != comment.userId) return;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('Edit comment'),
                onTap: () {
                  Navigator.pop(context);
                  _showEditCommentDialog(comment);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete comment'),
                onTap: () {
                  Navigator.pop(context);
                  _confirmDeleteComment(comment);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<String?> _getUserImageUrl(String userId) async {
    if (_userImageCache.containsKey(userId)) {
      return _userImageCache[userId];
    }
    final doc =
        await FirebaseFirestore.instance.collection('users').doc(userId).get();
    final url = doc.data()?['imageUrl'] as String?;
    _userImageCache[userId] = url;
    return url;
  }

  String _formatRelativeTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    final weeks = (diff.inDays / 7).floor();
    if (weeks < 5) return '${weeks}w ago';
    final months = (diff.inDays / 30).floor();
    if (months < 12) return '${months}mo ago';
    final years = (diff.inDays / 365).floor();
    return '${years}y ago';
  }

  Widget _buildCommentTile(Comment comment) {
    final initial = comment.userName.isNotEmpty
        ? comment.userName.trim()[0].toUpperCase()
        : '?';
    final timeLabel = _formatRelativeTime(comment.createdAt);
    return GestureDetector(
      onLongPress: () => _showCommentActions(comment),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => context.push(
                AppRoutes.clientProfilePath(comment.userId),
              ),
              borderRadius: BorderRadius.circular(14),
              child: FutureBuilder<String?>(
                future: _getUserImageUrl(comment.userId),
                builder: (context, snap) {
                  final imageUrl = snap.data;
                  return CircleAvatar(
                    radius: 12,
                    backgroundColor: AppColors.primary.withOpacity(0.2),
                    backgroundImage:
                        imageUrl != null && imageUrl.isNotEmpty
                            ? CachedNetworkImageProvider(imageUrl)
                            : null,
                    child: imageUrl == null || imageUrl.isEmpty
                        ? Text(
                            initial,
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          )
                        : null,
                  );
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => context.push(
                            AppRoutes.clientProfilePath(comment.userId),
                          ),
                          child: Text(
                            comment.userName,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: AppColors.primary,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                      Text(
                        timeLabel,
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.5),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    comment.content,
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoPage(PostMedia item, int index) {
    final isActive = index == _mediaIndex;
    if (!isActive) {
      return Container(
        color: AppColors.lightGrey,
        child: const Center(
          child: Icon(Icons.play_circle_fill, size: 52),
        ),
      );
    }
    return _videoController != null && _videoController!.value.isInitialized
        ? Stack(
            children: [
              Positioned.fill(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _videoController!.value.size.width,
                    height: _videoController!.value.size.height,
                    child: VideoPlayer(_videoController!),
                  ),
                ),
              ),
              Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: Column(
                  children: [
                    VideoProgressIndicator(
                      _videoController!,
                      allowScrubbing: true,
                      colors: VideoProgressColors(
                        playedColor: Theme.of(context).colorScheme.primary,
                        bufferedColor: Colors.white24,
                        backgroundColor: Colors.white10,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        ValueListenableBuilder(
                          valueListenable: _videoController!,
                          builder: (context, value, _) {
                            final isPlaying = value.isPlaying;
                            return IconButton(
                              icon: Icon(
                                isPlaying ? Icons.pause : Icons.play_arrow,
                                color: Colors.white,
                              ),
                              onPressed: () {
                                isPlaying
                                    ? _videoController!.pause()
                                    : _videoController!.play();
                              },
                            );
                          },
                        ),
                        ValueListenableBuilder(
                          valueListenable: _videoController!,
                          builder: (context, value, _) {
                            return Text(
                              '${_formatDuration(value.position)} / ${_formatDuration(value.duration)}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white70,
                              ),
                            );
                          },
                        ),
                        const Spacer(),
                        ValueListenableBuilder<bool>(
                          valueListenable: _isMuted,
                          builder: (context, muted, _) {
                            return IconButton(
                              icon: Icon(
                                muted ? Icons.volume_off : Icons.volume_up,
                                color: Colors.white,
                              ),
                              onPressed: () {
                                final next = !muted;
                                _isMuted.value = next;
                                _videoController!.setVolume(next ? 0 : 1);
                              },
                            );
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          )
        : Container(
            color: AppColors.lightGrey,
            child: const Center(
              child: CircularProgressIndicator(),
            ),
          );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Post')),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('posts')
            .doc(widget.post.id)
            .snapshots(),
        builder: (context, snap) {
          final post = snap.hasData && snap.data!.exists
              ? Post.fromFirestore(snap.data!)
              : widget.post;
          final media = post.media;
          if (media.isNotEmpty && _currentVideoUrl == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              _handleMediaIndexChange(media, _mediaIndex);
            });
          }
          final currentUser = FirebaseAuth.instance.currentUser;
          final isLiked =
              currentUser != null && post.likes.contains(currentUser.uid);
          final sortedComments = List<Comment>.from(post.comments)
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
          return Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: AppColors.primary,
                          backgroundImage: post.businessImageUrl != null &&
                                  post.businessImageUrl!.isNotEmpty
                              ? CachedNetworkImageProvider(
                                  post.businessImageUrl!,
                                )
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
                          child: Text(
                            post.businessName.isNotEmpty
                                ? post.businessName
                                : 'Creator',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (media.isEmpty) ...[
                      const SizedBox(height: 12),
                      Text(post.content),
                    ],
                    if (media.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          height: 360,
                          child: PageView.builder(
                            controller: _controller,
                            itemCount: media.length,
                            onPageChanged: (index) {
                              setState(() => _mediaIndex = index);
                              _handleMediaIndexChange(media, index);
                            },
                            itemBuilder: (context, index) {
                              final item = media[index];
                              if (!item.isVideo) {
                                return CachedNetworkImage(
                                  imageUrl: item.url,
                                  fit: BoxFit.cover,
                                );
                              }
                              return _buildVideoPage(item, index);
                            },
                          ),
                        ),
                      ),
                      if (post.content.trim().isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(post.content),
                      ],
                      if (media.length > 1) ...[
                        const SizedBox(height: 8),
                        Center(
                          child: SmoothPageIndicator(
                            controller: _controller,
                            count: media.length,
                            effect: const WormEffect(
                              dotHeight: 6,
                              dotWidth: 6,
                              activeDotColor: AppColors.primary,
                            ),
                          ),
                        ),
                      ],
                    ],
                    const SizedBox(height: 12),
                    StreamBuilder<DocumentSnapshot>(
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
                        return Row(
                          children: [
                            Expanded(
                              child: Row(
                                children: [
                                  IconButton(
                                    icon: Icon(
                                      isLiked
                                          ? Icons.favorite
                                          : Icons.favorite_border,
                                      color:
                                          isLiked ? Colors.pinkAccent : null,
                                    ),
                                    onPressed: () => _repo.toggleLike(post.id),
                                  ),
                                  Text('${post.likes.length}'),
                                  const SizedBox(width: 16),
                                  const Icon(Icons.chat_bubble_outline),
                                  const SizedBox(width: 6),
                                  Text('${post.comments.length}'),
                                  const SizedBox(width: 16),
                                  IconButton(
                                    icon: const Icon(Icons.forward),
                                    onPressed: () {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'Share feature coming soon!',
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 22),
                            Row(
                              children: [
                                if (post.googleMapsLink != null &&
                                    post.googleMapsLink!.isNotEmpty)
                                  IconButton(
                                    icon: const Icon(Icons.location_on),
                                    onPressed: () =>
                                        _openLocation(post.googleMapsLink),
                                  ),
                                IconButton(
                                  icon: Icon(
                                    isSaved
                                        ? Icons.bookmark
                                        : Icons.bookmark_border,
                                    color:
                                        isSaved ? AppColors.primary : null,
                                  ),
                                  onPressed: () => _toggleFavorite(post.id),
                                ),
                              ],
                            ),
                          ],
                        );
                      },
                    ),
                    const Divider(),
                    const Text(
                      'Comments',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    if (sortedComments.isEmpty)
                      const Text('No comments yet'),
                    ...sortedComments.map(_buildCommentTile),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  border: Border(
                    top: BorderSide(
                      color: Theme.of(context).dividerColor,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _commentController,
                        minLines: 1,
                        maxLines: 3,
                        decoration: InputDecoration(
                          hintText: 'Write a comment...',
                          filled: true,
                          fillColor: Theme.of(context)
                              .colorScheme
                              .surface
                              .withOpacity(0.6),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(18),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: () => _addComment(post.id),
                      borderRadius: BorderRadius.circular(18),
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppColors.primary,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: const Icon(
                          Icons.send,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
