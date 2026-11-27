import 'package:businessfinder/core/widgets/emoji_picker.dart';
import 'dart:async';
import 'package:businessfinder/core/i18n/tr.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:businessfinder/features/posts/data/engagement_repository.dart';
import 'package:video_player/video_player.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';
import 'dart:io';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/theme/colors.dart';
import '../../../data/models/post_model.dart';
import '../../../data/repositories/posts_repository.dart';
import 'package:businessfinder/core/widgets/app_toast.dart';

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
  // Comments are their own documents now (Phase 2): one live listener.
  List<Comment> _serverComments = const [];
  StreamSubscription<List<Comment>>? _commentsSub;
  late final PageController _pageController;
  int _mediaIndex = 0;
  VideoPlayerController? _videoController;
  Player? _mediaKitPlayer;
  VideoController? _mediaKitController;
  String? _currentVideoUrl;
  final ValueNotifier<bool> _isMuted = ValueNotifier<bool>(false);

  void _onLikesChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    LikeStore.instance.addListener(_onLikesChanged);
    _commentsSub = _repo.watchComments(widget.postId).listen((comments) {
      if (mounted) setState(() => _serverComments = comments);
    }, onError: (_) {});
    _mediaIndex = widget.initialMediaIndex;
    _pageController = PageController(
      initialPage: _mediaIndex,
      keepPage: true,
    );
  }

  @override
  void dispose() {
    LikeStore.instance.removeListener(_onLikesChanged);
    _commentsSub?.cancel();
    _commentController.dispose();
    _pageController.dispose();
    if (Platform.isWindows) {
      _mediaKitPlayer?.dispose();
    } else {
      _videoController?.dispose();
    }
    _isMuted.dispose();
    super.dispose();
  }

  void _initVideo(String url) async {
    if (Platform.isWindows) {
      _mediaKitPlayer?.dispose();
      _mediaKitPlayer = Player();
      _mediaKitController = VideoController(_mediaKitPlayer!);
      try {
        await _mediaKitPlayer!.open(Media(url));
        _currentVideoUrl = url;
        if (mounted) {
          setState(() {});
          _mediaKitPlayer!.setVolume(_isMuted.value ? 0 : 100);
          _mediaKitPlayer!.play();
        }
      } catch (e) {
        // Handle error silently
      }
    } else {
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
  }

  void _handleMediaIndexChange(List<PostMedia> media, int index) {
    if (media.isEmpty) return;
    final current = media[index.clamp(0, media.length - 1)];
    if (current.isVideo) {
      if (_currentVideoUrl != current.url) {
        _initVideo(current.url);
      }
    } else {
      if (Platform.isWindows) {
        _mediaKitPlayer?.pause();
      } else {
        _videoController?.pause();
      }
      _currentVideoUrl = null;
    }
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
      showToast(context, tr('Could not open Google Maps'));
    }
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Widget _buildVideoPage(PostMedia item, int index) {
    final isActive = index == _mediaIndex;
    if (!isActive) {
      return Container(
        color: AppColors.lightGrey,
        child: const Center(
          child: Icon(Icons.play_circle_fill, size: 48),
        ),
      );
    }
    final isInitialized = Platform.isWindows
        ? _mediaKitPlayer != null
        : _videoController != null && _videoController!.value.isInitialized;
    return isInitialized
        ? Column(
            children: [
              Expanded(
                child: SizedBox(
                  width: double.infinity,
                  child: Platform.isWindows
                      ? Video(controller: _mediaKitController!)
                      : FittedBox(
                          fit: BoxFit.cover,
                          child: SizedBox(
                            width: _videoController!.value.size.width,
                            height: _videoController!.value.size.height,
                            child: VideoPlayer(_videoController!),
                          ),
                        ),
                ),
              ),
              if (!Platform.isWindows)
                VideoProgressIndicator(
                  _videoController!,
                  allowScrubbing: true,
                  colors: VideoProgressColors(
                    playedColor: Theme.of(context).colorScheme.primary,
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
                    IconButton(
                      icon: Icon(
                        Platform.isWindows
                            ? (_mediaKitPlayer!.state.playing
                                ? Icons.pause
                                : Icons.play_arrow)
                            : (_videoController!.value.isPlaying
                                ? Icons.pause
                                : Icons.play_arrow),
                      ),
                      onPressed: () {
                        if (Platform.isWindows) {
                          _mediaKitPlayer!.state.playing
                              ? _mediaKitPlayer!.pause()
                              : _mediaKitPlayer!.play();
                        } else {
                          _videoController!.value.isPlaying
                              ? _videoController!.pause()
                              : _videoController!.play();
                        }
                      },
                    ),
                    Text(
                      Platform.isWindows
                          ? '${_formatDuration(_mediaKitPlayer!.state.position)} / ${_formatDuration(_mediaKitPlayer!.state.duration)}'
                          : '${_formatDuration(_videoController!.value.position)} / ${_formatDuration(_videoController!.value.duration)}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    const Spacer(),
                    ValueListenableBuilder<bool>(
                      valueListenable: _isMuted,
                      builder: (context, muted, _) {
                        return IconButton(
                          icon: Icon(
                            muted ? Icons.volume_off : Icons.volume_up,
                          ),
                          onPressed: () {
                            final next = !muted;
                            _isMuted.value = next;
                            if (Platform.isWindows) {
                              _mediaKitPlayer!.setVolume(next ? 0 : 100);
                            } else {
                              _videoController!.setVolume(next ? 0 : 1);
                            }
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
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Post'))),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('posts')
            .doc(widget.postId)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snapshot.hasData || !snapshot.data!.exists) {
            return Center(child: Text(tr('Post not found')));
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
          if (media.isNotEmpty && _currentVideoUrl == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              _handleMediaIndexChange(media, _mediaIndex);
            });
          }

          final isLiked = user != null && LikeStore.instance.isLiked(post.id);

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
                    if (media.isEmpty) ...[
                      Text(post.content),
                    ],
                    if (media.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          height: 360,
                          child: PageView.builder(
                            key: PageStorageKey(
                              'post_media_${widget.postId}',
                            ),
                            controller: _pageController,
                            itemCount: media.length,
                            physics: const PageScrollPhysics(),
                            onPageChanged: (value) {
                              setState(() => _mediaIndex = value);
                              _handleMediaIndexChange(media, value);
                            },
                            itemBuilder: (context, index) {
                              final item = media[index];
                              final overlayBottom = item.isVideo ? 56.0 : 0.0;
                              return KeyedSubtree(
                                key: ValueKey(item.url),
                                child: Stack(
                                  children: [
                                    Positioned.fill(
                                      child: !item.isVideo
                                          ? Image.network(
                                              item.url,
                                              width: double.infinity,
                                              fit: BoxFit.cover,
                                            )
                                          : _buildVideoPage(item, index),
                                    ),
                                    if (post.content.trim().isNotEmpty)
                                      Positioned(
                                        left: 0,
                                        right: 0,
                                        bottom: overlayBottom,
                                        child: Container(
                                          padding: const EdgeInsets.fromLTRB(
                                              12, 24, 12, 10),
                                          decoration: const BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: Alignment.topCenter,
                                              end: Alignment.bottomCenter,
                                              colors: [
                                                Colors.transparent,
                                                Colors.black54,
                                              ],
                                            ),
                                          ),
                                          child: Text(
                                            post.content,
                                            maxLines: 3,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              height: 1.3,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
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
                                isLiked
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                color: isLiked ? Colors.pinkAccent : null,
                              ),
                              onPressed: () => _repo.toggleLike(post.id),
                            ),
                            Text('${post.likeCount}'),
                            const SizedBox(width: 16),
                            const Icon(Icons.chat_bubble_outline),
                            const SizedBox(width: 6),
                            Text('${post.commentCount}'),
                            const SizedBox(width: 16),
                            IconButton(
                              icon: const Icon(Icons.forward),
                              onPressed: () {
                                showToast(context, tr('Share feature coming soon!'));
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
                                isSaved
                                    ? Icons.bookmark
                                    : Icons.bookmark_border,
                                color: isSaved ? AppColors.primary : null,
                              ),
                              onPressed: () => _toggleFavorite(post.id),
                            ),
                          ],
                        );
                      },
                    ),
                    const Divider(),
                    Text(
                      tr('Comments'),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    if (_serverComments.isEmpty) Text(tr('No comments yet')),
                    ..._serverComments.reversed.map(
                      (c) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${c.userName}: ',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold),
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
                        decoration: InputDecoration(
                          suffixIcon:
                              EmojiButton(controller: _commentController),
                          hintText: tr('Write a comment...'),
                          border: const OutlineInputBorder(),
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
