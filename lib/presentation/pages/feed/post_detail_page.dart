import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';

import '../../../core/theme/colors.dart';
import '../../../data/models/post_model.dart';
import '../../../data/repositories/posts_repository.dart';

class PostDetailPage extends StatefulWidget {
  const PostDetailPage({
    super.key,
    required this.postId,
    this.initialMediaIndex = 0,
  });

  final String postId;
  final int initialMediaIndex;

  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends State<PostDetailPage> {
  final _commentController = TextEditingController();
  final _repo = PostsRepository();
  late final PageController _pageController;
  int _mediaIndex = 0;
  VideoPlayerController? _videoController;
  String? _currentVideoUrl;
  final ValueNotifier<bool> _isMuted = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    _mediaIndex = widget.initialMediaIndex;
    _pageController = PageController(initialPage: _mediaIndex);
  }

  @override
  void dispose() {
    _commentController.dispose();
    _pageController.dispose();
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

  Future<void> _addComment(String postId) async {
    final text = _commentController.text.trim();
    if (text.isEmpty) return;
    await _repo.addComment(postId, text);
    _commentController.clear();
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

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    return Scaffold(
      appBar: AppBar(title: const Text('Post')),
      body: StreamBuilder<DocumentSnapshot>(
        stream:
            FirebaseFirestore.instance.collection('posts').doc(widget.postId).snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snapshot.hasData || !snapshot.data!.exists) {
            return const Center(child: Text('Post not found'));
          }
          final post = Post.fromFirestore(snapshot.data!);
          final media = post.media;
          if (_mediaIndex >= media.length && media.isNotEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              setState(() => _mediaIndex = 0);
              _pageController.jumpToPage(0);
            });
          }
          if (media.isNotEmpty) {
            final current = media[_mediaIndex.clamp(0, media.length - 1)];
            if (current.isVideo && _currentVideoUrl != current.url) {
              _initVideo(current.url);
            } else if (!current.isVideo) {
              _videoController?.pause();
            }
          }

          final isLiked =
              user != null && post.likes.contains(user.uid);

          return Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  children: [
                    Text(
                      post.businessName,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(post.content),
                    if (media.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          height: 300,
                          child: PageView.builder(
                            controller: _pageController,
                            itemCount: media.length,
                            physics: const PageScrollPhysics(),
                            onPageChanged: (value) {
                              setState(() => _mediaIndex = value);
                            },
                            itemBuilder: (context, index) {
                              final item = media[index];
                              if (!item.isVideo) {
                                return Image.network(
                                  item.url,
                                  width: double.infinity,
                                  fit: BoxFit.cover,
                                );
                              }
                              final isActive = index == _mediaIndex;
                              if (!isActive) {
                                return Container(
                                  color: AppColors.lightGrey,
                                  child: const Center(
                                    child: Icon(Icons.play_circle_fill, size: 48),
                                  ),
                                );
                              }
                              return _videoController != null &&
                                      _videoController!.value.isInitialized
                                  ? Column(
                                      children: [
                                        Expanded(
                                          child: SizedBox(
                                            width: double.infinity,
                                            child: FittedBox(
                                              fit: BoxFit.cover,
                                              child: SizedBox(
                                                width: _videoController!
                                                    .value.size.width,
                                                height: _videoController!
                                                    .value.size.height,
                                                child: VideoPlayer(_videoController!),
                                              ),
                                            ),
                                          ),
                                        ),
                                        VideoProgressIndicator(
                                          _videoController!,
                                          allowScrubbing: true,
                                          colors: VideoProgressColors(
                                            playedColor: Theme.of(context)
                                                .colorScheme
                                                .primary,
                                            bufferedColor: Colors.white24,
                                            backgroundColor: Colors.white10,
                                          ),
                                        ),
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 6,
                                          ),
                                          child: Row(
                                            children: [
                                              ValueListenableBuilder(
                                                valueListenable: _videoController!,
                                                builder: (context, value, _) {
                                                  final isPlaying = value.isPlaying;
                                                  return IconButton(
                                                    icon: Icon(isPlaying
                                                        ? Icons.pause
                                                        : Icons.play_arrow),
                                                    onPressed: () {
                                                      isPlaying
                                                          ? _videoController!
                                                              .pause()
                                                          : _videoController!
                                                              .play();
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
                                                    ),
                                                  );
                                                },
                                              ),
                                              const Spacer(),
                                              ValueListenableBuilder<bool>(
                                                valueListenable: _isMuted,
                                                builder: (context, muted, _) {
                                                  return IconButton(
                                                    icon: Icon(muted
                                                        ? Icons.volume_off
                                                        : Icons.volume_up),
                                                    onPressed: () {
                                                      final next = !muted;
                                                      _isMuted.value = next;
                                                      _videoController!
                                                          .setVolume(
                                                              next ? 0 : 1);
                                                    },
                                                  );
                                                },
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
                            },
                          ),
                        ),
                      ),
                      if (media.length > 1) ...[
                        const SizedBox(height: 8),
                        Center(
                          child: SmoothPageIndicator(
                            controller: _pageController,
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
                      stream: user == null
                          ? const Stream.empty()
                          : FirebaseFirestore.instance
                              .collection('users')
                              .doc(user.uid)
                              .collection('favorites')
                              .doc(post.id)
                              .snapshots(),
                      builder: (context, favSnap) {
                        final isSaved = favSnap.data?.exists == true;
                        return Row(
                          children: [
                            IconButton(
                              icon: Icon(
                                isLiked ? Icons.star : Icons.star_border,
                                color: isLiked ? Colors.amber : null,
                              ),
                              onPressed: () => _repo.toggleLike(post.id),
                            ),
                            Text('${post.likes.length}'),
                            const SizedBox(width: 16),
                            const Icon(Icons.comment),
                            const SizedBox(width: 6),
                            Text('${post.comments.length}'),
                            const SizedBox(width: 16),
                            IconButton(
                              icon: const Icon(Icons.share),
                              onPressed: () {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Share feature coming soon!'),
                                  ),
                                );
                              },
                            ),
                            const Spacer(),
                            if (post.googleMapsLink != null &&
                                post.googleMapsLink!.isNotEmpty)
                              IconButton(
                                icon: const Icon(Icons.location_on),
                                onPressed: () =>
                                    _openLocation(post.googleMapsLink),
                              ),
                            IconButton(
                              icon: Icon(
                                isSaved ? Icons.bookmark : Icons.bookmark_border,
                                color: isSaved ? AppColors.primary : null,
                              ),
                              onPressed: () => _toggleFavorite(post.id),
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
                    if (post.comments.isEmpty)
                      const Text('No comments yet'),
                    ...post.comments.reversed.map(
                      (c) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${c.userName}: ',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            Expanded(child: Text(c.content)),
                          ],
                        ),
                      ),
                    ),
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
                        decoration: const InputDecoration(
                          hintText: 'Write a comment...',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.send),
                      onPressed: () => _addComment(post.id),
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
