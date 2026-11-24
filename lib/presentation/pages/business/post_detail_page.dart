import 'dart:async';

import 'package:flutter/material.dart';
import 'package:businessfinder/features/posts/data/engagement_repository.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';
import 'package:video_player/video_player.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:go_router/go_router.dart';
import 'dart:io';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

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
  // Comments are their own documents now (Phase 2): one live listener.
  List<Comment> _serverComments = const [];
  StreamSubscription<List<Comment>>? _commentsSub;
  final Map<String, String?> _userImageCache = {};
  final List<Comment> _pendingComments = [];
  final ScrollController _commentsScrollController = ScrollController();
  final Map<String, GlobalKey> _commentKeys = {};
  Comment? _replyingToComment;
  final Set<String> _collapsedReplyParents = {};
  String? _highlightedCommentId;
  Timer? _highlightTimer;
  int _mediaIndex = 0;
  VideoPlayerController? _videoController;
  Player? _mediaKitPlayer;
  VideoController? _mediaKitController;
  String? _currentVideoUrl;
  bool _isVideoReady = false;
  final ValueNotifier<bool> _isMuted = ValueNotifier<bool>(false);
  bool _isSubmittingComment = false;

  void _onLikesChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    LikeStore.instance.addListener(_onLikesChanged);
    _commentsSub = _repo.watchComments(widget.post.id).listen((comments) {
      if (mounted) setState(() => _serverComments = comments);
    }, onError: (_) {});
    _mediaIndex = widget.initialMediaIndex;
    _controller = PageController(initialPage: _mediaIndex);
    if (widget.post.media.isNotEmpty) {
      _handleMediaIndexChange(widget.post.media, _mediaIndex);
    }
  }

  @override
  void dispose() {
    LikeStore.instance.removeListener(_onLikesChanged);
    _commentsSub?.cancel();
    _controller.dispose();
    _commentController.dispose();
    _commentsScrollController.dispose();
    if (Platform.isWindows) {
      _mediaKitPlayer?.dispose();
    } else {
      _videoController?.dispose();
    }
    _isMuted.dispose();
    _highlightTimer?.cancel();
    super.dispose();
  }

  void _flashCommentHighlight(String commentId) {
    _highlightTimer?.cancel();
    setState(() {
      _highlightedCommentId = commentId;
    });
    _highlightTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      setState(() {
        _highlightedCommentId = null;
      });
    });
  }

  Future<void> _focusParentComment(String commentId) async {
    if (commentId.isEmpty) return;
    setState(() {
      _collapsedReplyParents.remove(commentId);
    });
    await Future<void>.delayed(const Duration(milliseconds: 40));
    if (!mounted) return;
    _flashCommentHighlight(commentId);
    final contextForComment = _commentKeys[commentId]?.currentContext;
    if (contextForComment != null) {
      await Scrollable.ensureVisible(
        contextForComment,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        alignment: 0.2,
      );
    }
  }

  void _initVideo(String url) async {
    if (mounted) {
      setState(() {
        _isVideoReady = false;
      });
    }

    if (Platform.isWindows) {
      _mediaKitPlayer?.dispose();
      _mediaKitPlayer = Player();
      _mediaKitController = VideoController(_mediaKitPlayer!);
      try {
        await _mediaKitPlayer!.open(Media(url));
        _mediaKitPlayer!.setPlaylistMode(PlaylistMode.loop);
        _currentVideoUrl = url;
        if (mounted) {
          setState(() {
            _isVideoReady = true;
          });
          _mediaKitPlayer!.setVolume(_isMuted.value ? 0 : 100);
          _mediaKitPlayer!.play();
        }
      } catch (e) {
        debugPrint('Post detail Windows video failed: $e');
        if (mounted) {
          setState(() {
            _isVideoReady = false;
          });
        }
      }
    } else {
      _videoController?.dispose();
      final controller = VideoPlayerController.networkUrl(Uri.parse(url));
      _videoController = controller;
      _currentVideoUrl = url;
      controller.initialize().then((_) {
        if (mounted) {
          setState(() {
            _isVideoReady = true;
          });
          controller.setLooping(true);
          controller.setVolume(_isMuted.value ? 0 : 1);
          controller.play();
        }
      }).catchError((error) {
        debugPrint('Post detail mobile video failed: $error');
        if (mounted) {
          setState(() {
            _isVideoReady = false;
          });
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
      _isVideoReady = false;
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
    HapticFeedback.selectionClick();
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
    final user = FirebaseAuth.instance.currentUser;
    if (text.isEmpty || user == null || _isSubmittingComment) return;
    HapticFeedback.selectionClick();
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    final userName =
        (userDoc.data()?['name'] as String?)?.trim().isNotEmpty == true
            ? (userDoc.data()?['name'] as String).trim()
            : (user.displayName?.trim().isNotEmpty == true
                ? user.displayName!.trim()
                : 'You');
    final optimistic = Comment(
      id: 'pending_${DateTime.now().microsecondsSinceEpoch}',
      userId: user.uid,
      userName: userName,
      content: text,
      createdAt: DateTime.now(),
      replyToUserId: _replyingToComment?.userId,
      replyToUserName: _replyingToComment?.userName,
      replyToCommentId: _replyingToComment?.id,
    );
    setState(() {
      _isSubmittingComment = true;
      _pendingComments.insert(0, optimistic);
    });
    _commentController.clear();
    try {
      await _repo.addComment(
        postId,
        text,
        replyTo: _replyingToComment,
      );
      if (!mounted) return;
      setState(() {
        _pendingComments.removeWhere((comment) => comment.id == optimistic.id);
        _replyingToComment = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pendingComments.removeWhere((comment) => comment.id == optimistic.id);
      });
      _commentController.text = text;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Comment not sent. Check your connection. ($e)')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSubmittingComment = false;
        });
      }
    }
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
                leading: const Icon(Icons.reply_rounded),
                title: const Text('Reply'),
                onTap: () {
                  Navigator.pop(context);
                  setState(() {
                    _replyingToComment = comment;
                  });
                  FocusScope.of(context).requestFocus(FocusNode());
                },
              ),
              if (currentUser != null && currentUser.uid == comment.userId)
                ListTile(
                  leading: const Icon(Icons.edit),
                  title: const Text('Edit comment'),
                  onTap: () {
                    Navigator.pop(context);
                    _showEditCommentDialog(comment);
                  },
                ),
              if (currentUser != null && currentUser.uid == comment.userId)
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

  String _formatMetric(int value) {
    if (value >= 1000000) {
      final compact = value / 1000000;
      return '${compact.toStringAsFixed(compact >= 10 ? 0 : 1).replaceAll('.0', '')}M';
    }
    if (value >= 1000) {
      final compact = value / 1000;
      return '${compact.toStringAsFixed(compact >= 10 ? 0 : 1).replaceAll('.0', '')}K';
    }
    return value.toString();
  }

  void _showShareSheet(Post post) {
    HapticFeedback.selectionClick();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final isDark = Theme.of(sheetContext).brightness == Brightness.dark;
        final thumb = post.media.isNotEmpty ? post.media.first.url : null;
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF141821) : Colors.white,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white24 : Colors.black12,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Share this post',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.04)
                        : Colors.black.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: SizedBox(
                          width: 56,
                          height: 56,
                          child: thumb != null && thumb.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: thumb,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, __, ___) => Container(
                                    color: AppColors.lightGrey,
                                    child: const Icon(Icons.photo),
                                  ),
                                )
                              : Container(
                                  color: AppColors.lightGrey,
                                  child: const Icon(Icons.photo),
                                ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              post.businessName.isNotEmpty
                                  ? post.businessName
                                  : 'Creator',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              post.content.trim().isEmpty
                                  ? 'Share this moment.'
                                  : post.content,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: AppColors.grey),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _SheetAction(
                      icon: Icons.send_rounded,
                      label: 'Send',
                      onTap: () {
                        HapticFeedback.selectionClick();
                        Navigator.pop(sheetContext);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text(
                                  'Open chat from feed to send this post')),
                        );
                      },
                    ),
                    _SheetAction(
                      icon: Icons.copy_rounded,
                      label: 'Copy text',
                      onTap: () async {
                        HapticFeedback.lightImpact();
                        await Clipboard.setData(
                          ClipboardData(
                            text: post.content.trim().isEmpty
                                ? 'Check out this Duhuze post from ${post.businessName}'
                                : post.content,
                          ),
                        );
                        if (!mounted) return;
                        Navigator.pop(sheetContext);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Caption copied')),
                        );
                      },
                    ),
                    _SheetAction(
                      icon: Icons.person_outline_rounded,
                      label: 'Creator',
                      onTap: () {
                        HapticFeedback.selectionClick();
                        Navigator.pop(sheetContext);
                        if (post.businessId.isNotEmpty) {
                          context.push(
                              AppRoutes.businessProfilePath(post.businessId));
                        } else {
                          context
                              .push(AppRoutes.clientProfilePath(post.ownerId));
                        }
                      },
                    ),
                    _SheetAction(
                      icon: Icons.link_rounded,
                      label: 'Copy ID',
                      onTap: () async {
                        HapticFeedback.lightImpact();
                        await Clipboard.setData(ClipboardData(text: post.id));
                        if (!mounted) return;
                        Navigator.pop(sheetContext);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Post ID copied')),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _buildCommentThreads(List<Comment> comments) {
    final byId = <String, Comment>{
      for (final comment in comments) comment.id: comment
    };
    final repliesByParent = <String, List<Comment>>{};
    final parents = <Comment>[];

    for (final comment in comments) {
      final parentId = comment.replyToCommentId;
      if (parentId != null &&
          parentId.isNotEmpty &&
          byId.containsKey(parentId)) {
        repliesByParent.putIfAbsent(parentId, () => []).add(comment);
      } else {
        parents.add(comment);
      }
    }

    parents.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    for (final replies in repliesByParent.values) {
      replies.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }

    final widgets = <Widget>[];
    void addBranch(Comment comment, int depth) {
      final replies = repliesByParent[comment.id] ?? const <Comment>[];
      widgets.add(
        _buildCommentTile(
          comment,
          depth: depth,
          replyCount: replies.length,
          repliesCollapsed: _collapsedReplyParents.contains(comment.id),
        ),
      );
      if (_collapsedReplyParents.contains(comment.id)) {
        return;
      }
      for (final reply in replies) {
        addBranch(reply, depth + 1);
      }
    }

    for (final parent in parents) {
      addBranch(parent, 0);
    }
    return widgets;
  }

  Widget _buildCommentTile(
    Comment comment, {
    int depth = 0,
    int replyCount = 0,
    bool repliesCollapsed = false,
  }) {
    final initial = comment.userName.isNotEmpty
        ? comment.userName.trim()[0].toUpperCase()
        : '?';
    final timeLabel = _formatRelativeTime(comment.createdAt);
    final currentUser = FirebaseAuth.instance.currentUser;
    final isLikedByMe =
        currentUser != null && comment.likes.contains(currentUser.uid);
    final isReply = depth > 0;
    _commentKeys.putIfAbsent(comment.id, () => GlobalKey());
    return KeyedSubtree(
        key: _commentKeys[comment.id],
        child: GestureDetector(
          onLongPress: () => _showCommentActions(comment),
          child: Padding(
            padding: EdgeInsets.only(
              top: 6,
              bottom: 6,
              left: depth * 18,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isReply)
                  Container(
                    width: 12,
                    margin: const EdgeInsets.only(top: 14, right: 8),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Container(
                        width: 10,
                        height: 26,
                        decoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.12),
                              width: 2,
                            ),
                            bottom: BorderSide(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.12),
                              width: 2,
                            ),
                          ),
                          borderRadius: const BorderRadius.only(
                            bottomLeft: Radius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  ),
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
                        backgroundColor:
                            AppColors.primary.withValues(alpha: 0.2),
                        backgroundImage: imageUrl != null && imageUrl.isNotEmpty
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
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    decoration: BoxDecoration(
                      color: _highlightedCommentId == comment.id
                          ? AppColors.primary.withValues(alpha: 0.13)
                          : Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest
                              .withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: _highlightedCommentId == comment.id
                            ? AppColors.primary.withValues(alpha: 0.28)
                            : Colors.transparent,
                      ),
                    ),
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
                                    .withValues(alpha: 0.5),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        if (comment.replyToUserName != null &&
                            comment.replyToUserName!.trim().isNotEmpty) ...[
                          InkWell(
                            onTap: () {
                              final parentId = comment.replyToCommentId;
                              if (parentId != null && parentId.isNotEmpty) {
                                HapticFeedback.selectionClick();
                                _focusParentComment(parentId);
                              }
                            },
                            borderRadius: BorderRadius.circular(999),
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color:
                                    AppColors.primary.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                'Replying to @${comment.replyToUserName}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.primary,
                                ),
                              ),
                            ),
                          ),
                        ],
                        Text(
                          comment.content,
                          style: const TextStyle(fontSize: 13, height: 1.35),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            InkWell(
                              onTap: () async {
                                HapticFeedback.selectionClick();
                                await _repo.toggleCommentLike(
                                  postId: widget.post.id,
                                  commentId: comment.id,
                                );
                              },
                              borderRadius: BorderRadius.circular(999),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 2,
                                  vertical: 2,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      isLikedByMe
                                          ? Icons.favorite_rounded
                                          : Icons.favorite_border_rounded,
                                      size: 14,
                                      color: isLikedByMe
                                          ? Colors.pinkAccent
                                          : Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: 0.65),
                                    ),
                                    if (comment.likes.isNotEmpty) ...[
                                      const SizedBox(width: 4),
                                      Text(
                                        '${comment.likes.length}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: isLikedByMe
                                              ? Colors.pinkAccent
                                              : Theme.of(context)
                                                  .colorScheme
                                                  .onSurface
                                                  .withValues(alpha: 0.65),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            InkWell(
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setState(() {
                                  _replyingToComment = comment;
                                });
                              },
                              borderRadius: BorderRadius.circular(999),
                              child: const Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 2,
                                  vertical: 2,
                                ),
                                child: Text(
                                  'Reply',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.grey,
                                  ),
                                ),
                              ),
                            ),
                            if (replyCount > 0) ...[
                              const SizedBox(width: 14),
                              InkWell(
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  setState(() {
                                    if (repliesCollapsed) {
                                      _collapsedReplyParents.remove(comment.id);
                                    } else {
                                      _collapsedReplyParents.add(comment.id);
                                    }
                                  });
                                },
                                borderRadius: BorderRadius.circular(999),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 2,
                                    vertical: 2,
                                  ),
                                  child: Text(
                                    repliesCollapsed
                                        ? 'View repl${replyCount == 1 ? 'y' : 'ies'} ($replyCount)'
                                        : 'Hide repl${replyCount == 1 ? 'y' : 'ies'}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.primary,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ));
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
    final isInitialized = Platform.isWindows
        ? _isVideoReady && _mediaKitController != null
        : _videoController != null && _videoController!.value.isInitialized;
    return isInitialized
        ? Container(
            color: Colors.black,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Center(
                    child: IgnorePointer(
                      ignoring: true,
                      child: Platform.isWindows
                          ? Video(
                              controller: _mediaKitController!,
                              fit: BoxFit.contain,
                            )
                          : FittedBox(
                              fit: BoxFit.contain,
                              child: SizedBox(
                                width: _videoController!.value.size.width,
                                height: _videoController!.value.size.height,
                                child: VideoPlayer(_videoController!),
                              ),
                            ),
                    ),
                  ),
                ),
                if (!Platform.isWindows)
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
                                    HapticFeedback.selectionClick();
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
                                    HapticFeedback.selectionClick();
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
            ),
          )
        : Container(
            color: Colors.black,
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
              currentUser != null && LikeStore.instance.isLiked(post.id);
          final mergedComments = <Comment>[
            ..._pendingComments,
            ..._serverComments.where(
              (serverComment) => !_pendingComments.any(
                (pending) =>
                    pending.userId == serverComment.userId &&
                    pending.content == serverComment.content &&
                    pending.createdAt
                            .difference(serverComment.createdAt)
                            .inSeconds
                            .abs() <
                        10,
              ),
            ),
          ];
          final threadedComments = _buildCommentThreads(mergedComments);
          final hasVideo = media.any((item) => item.isVideo);
          final isDesktopWide = MediaQuery.of(context).size.width >= 1180;
          final onSurfaceMuted =
              Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55);

          Widget commentsHeader() {
            return Row(
              children: [
                const Text(
                  'Comments',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${mergedComments.length}',
                    style: const TextStyle(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  'Newest first',
                  style: TextStyle(
                    color: onSurfaceMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            );
          }

          Widget emptyCommentsState() {
            return Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                children: [
                  Icon(Icons.mode_comment_outlined, color: AppColors.grey),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'No comments yet. Start the conversation.',
                      style: TextStyle(color: AppColors.grey),
                    ),
                  ),
                ],
              ),
            );
          }

          Widget commentComposer() {
            return Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border(
                  top: BorderSide(color: Theme.of(context).dividerColor),
                ),
              ),
              child: Row(
                children: [
                  FutureBuilder<String?>(
                    future: currentUser == null
                        ? Future.value(null)
                        : _getUserImageUrl(currentUser.uid),
                    builder: (context, snap) {
                      final imageUrl = snap.data;
                      final name = currentUser?.displayName?.trim();
                      return CircleAvatar(
                        radius: 18,
                        backgroundColor:
                            AppColors.primary.withValues(alpha: 0.2),
                        backgroundImage: imageUrl != null && imageUrl.isNotEmpty
                            ? CachedNetworkImageProvider(imageUrl)
                            : null,
                        child: imageUrl == null || imageUrl.isEmpty
                            ? Text(
                                (name != null && name.isNotEmpty
                                        ? name[0]
                                        : 'Y')
                                    .toUpperCase(),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              )
                            : null,
                      );
                    },
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_replyingToComment != null)
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.primary.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Replying to @${_replyingToComment!.userName}',
                                    style: const TextStyle(
                                      color: AppColors.primary,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                                InkWell(
                                  onTap: () {
                                    setState(() {
                                      _replyingToComment = null;
                                    });
                                  },
                                  child: const Icon(
                                    Icons.close_rounded,
                                    size: 16,
                                    color: AppColors.primary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        TextField(
                          controller: _commentController,
                          minLines: 1,
                          maxLines: 3,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _addComment(post.id),
                          decoration: InputDecoration(
                            hintText: _replyingToComment == null
                                ? 'Share your thoughts...'
                                : 'Write your reply...',
                            filled: true,
                            fillColor: Theme.of(context)
                                .colorScheme
                                .surface
                                .withValues(alpha: 0.6),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide.none,
                            ),
                            prefixIcon: const Icon(Icons.mode_comment_outlined),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () => _addComment(post.id),
                    borderRadius: BorderRadius.circular(24),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_isSubmittingComment) ...[
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 8),
                          ] else
                            const Icon(
                              Icons.send_rounded,
                              color: Colors.white,
                              size: 18,
                            ),
                          const Text(
                            'Post',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          }

          Widget postContentSection() {
            return ListView(
              controller: isDesktopWide ? null : _commentsScrollController,
              padding: const EdgeInsets.all(16),
              children: [
                Row(
                  children: [
                    InkWell(
                      onTap: () {
                        if (post.businessId.isNotEmpty) {
                          context.push(
                            AppRoutes.businessProfilePath(post.businessId),
                          );
                        } else {
                          context.push(
                            AppRoutes.clientProfilePath(post.ownerId),
                          );
                        }
                      },
                      borderRadius: BorderRadius.circular(999),
                      child: Row(
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
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                post.businessName.isNotEmpty
                                    ? post.businessName
                                    : 'Creator',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _formatRelativeTime(post.createdAt),
                      style: TextStyle(
                        color: onSurfaceMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                if (media.isEmpty) ...[
                  const SizedBox(height: 12),
                  if (post.content.trim().isNotEmpty) Text(post.content),
                ],
                if (media.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      height: isDesktopWide ? 500 : 430,
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
                          child: Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              IconButton(
                                icon: Icon(
                                  isLiked
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  color: isLiked ? Colors.pinkAccent : null,
                                ),
                                onPressed: () {
                                  HapticFeedback.lightImpact();
                                  _repo.toggleLike(post.id);
                                },
                              ),
                              Text('${post.likeCount}'),
                              const Icon(Icons.chat_bubble_outline),
                              Text('${post.commentCount}'),
                              IconButton(
                                icon: const Icon(Icons.forward),
                                onPressed: () => _showShareSheet(post),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Row(
                          children: [
                            if (post.googleMapsLink != null &&
                                post.googleMapsLink!.isNotEmpty)
                              IconButton(
                                icon: const Icon(Icons.location_on),
                                onPressed: () =>
                                    _openLocation(post.googleMapsLink),
                              ),
                            if (hasVideo)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: _DetailMetaChip(
                                  icon: Icons.play_arrow_rounded,
                                  label: _formatMetric(post.playCount),
                                  accent: Colors.pinkAccent,
                                ),
                              ),
                            IconButton(
                              icon: Icon(
                                isSaved
                                    ? Icons.bookmark
                                    : Icons.bookmark_border,
                                color: isSaved ? AppColors.primary : null,
                              ),
                              onPressed: () {
                                HapticFeedback.lightImpact();
                                _toggleFavorite(post.id);
                              },
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
                if (!isDesktopWide) ...[
                  const Divider(),
                  commentsHeader(),
                  const SizedBox(height: 8),
                  if (mergedComments.isEmpty) emptyCommentsState(),
                  ...threadedComments,
                ],
              ],
            );
          }

          if (isDesktopWide) {
            final cardColor = Theme.of(context).colorScheme.surface;
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 6,
                    child: Container(
                      decoration: BoxDecoration(
                        color: cardColor,
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(
                          color: Theme.of(context)
                              .dividerColor
                              .withValues(alpha: 0.5),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.06),
                            blurRadius: 18,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: postContentSection(),
                    ),
                  ),
                  const SizedBox(width: 18),
                  SizedBox(
                    width: 420,
                    child: Container(
                      decoration: BoxDecoration(
                        color: cardColor,
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(
                          color: Theme.of(context)
                              .dividerColor
                              .withValues(alpha: 0.5),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.06),
                            blurRadius: 18,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                            child: commentsHeader(),
                          ),
                          Divider(
                            height: 1,
                            color: Theme.of(context).dividerColor,
                          ),
                          Expanded(
                            child: ListView(
                              controller: _commentsScrollController,
                              padding: const EdgeInsets.all(16),
                              children: [
                                if (mergedComments.isEmpty)
                                  emptyCommentsState(),
                                ...threadedComments,
                              ],
                            ),
                          ),
                          commentComposer(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          }

          return Column(
            children: [
              Expanded(child: postContentSection()),
              commentComposer(),
            ],
          );
        },
      ),
    );
  }
}

class _DetailMetaChip extends StatelessWidget {
  const _DetailMetaChip({
    required this.icon,
    required this.label,
    this.accent,
  });

  final IconData icon;
  final String label;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final color = accent ?? AppColors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Ink(
        width: 92,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.black.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppColors.primary),
            const SizedBox(height: 8),
            Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
