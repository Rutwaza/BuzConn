import 'package:flutter/material.dart';
import 'package:businessfinder/core/services/lite_mode_service.dart';
import 'package:businessfinder/features/status/ui/status_bar.dart';
import 'package:businessfinder/core/i18n/tr.dart';
import 'package:businessfinder/core/services/video_compressor.dart';
import 'package:businessfinder/features/posts/logic/reel_prefetcher.dart';
import 'package:businessfinder/features/posts/data/engagement_repository.dart';
import 'package:businessfinder/features/chat/data/presence_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';
import 'dart:async';
import 'dart:io';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/notification_read_service.dart';
import '../../../core/theme/colors.dart';
import '../../../core/widgets/spotlight_loader.dart';
import '../../../data/models/post_model.dart';
import '../../../data/repositories/posts_repository.dart';
import 'package:businessfinder/features/chat/data/chat_repository.dart';
import '../../../core/services/r2_storage_service.dart';
import '../business/post_detail_page.dart' as business_post;
import 'package:visibility_detector/visibility_detector.dart';

class PostsFeedPage extends ConsumerStatefulWidget {
  const PostsFeedPage({super.key, this.initialPostId});

  final String? initialPostId;

  @override
  ConsumerState<PostsFeedPage> createState() => _PostsFeedPageState();
}

class _PostsFeedPageState extends ConsumerState<PostsFeedPage> {
  final PostsRepository _postsRepository = PostsRepository();
  final TextEditingController _commentController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final PageController _reelsPageController = PageController();
  final Map<String, int> _mediaIndexByPostId = {};
  static const int _pageSize = 10;
  final List<Post> _posts = [];
  DocumentSnapshot? _lastDoc;
  bool _isLoading = false;
  bool _isBootstrapping = true;
  bool _isRefreshing = false;
  bool _hasMore = true;
  String _feedMode = 'reels';
  bool _showModeTabs = false;
  List<String> _followingPageIds = [];
  List<String> _followingUserIds = [];
  DocumentSnapshot? _followingFallbackLastDoc;
  final ValueNotifier<Timestamp?> _badgeClearedAt =
      ValueNotifier<Timestamp?>(null);
  bool _didJumpToPost = false;
  final Map<String, double> _creatorAffinity = {};
  final Map<String, double> _postAffinity = {};
  final Set<String> _impressedPosts = {};
  final Set<String> _engagedMedia = {};
  final Map<String, String> _viewedHighlightPosts = {};
  bool _inlineSuggestionsDismissed = false;

  Future<void> _signOut() async {
    await PresenceService.instance.goOffline();
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    context.go(AppRoutes.login);
  }

  Future<void> _toggleFollowPage(String pageId, bool isFollowing) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || pageId.isEmpty) return;
    final docId = '${user.uid}_$pageId';
    final ref =
        FirebaseFirestore.instance.collection('page_follows').doc(docId);
    try {
      if (isFollowing) {
        await ref.delete();
      } else {
        await ref.set({
          'followerId': user.uid,
          'pageId': pageId,
          'createdAt': Timestamp.now(),
        });
      }
    } on FirebaseException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Follow update failed: ${e.message ?? e.code}')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Follow update failed'))),
      );
    }
  }

  @override
  void dispose() {
    LikeStore.instance.removeListener(_onLikesChanged);
    _commentController.dispose();
    _scrollController.dispose();
    _reelsPageController.dispose();
    _badgeClearedAt.dispose();
    super.dispose();
  }

  void _onLikesChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    LikeStore.instance.addListener(_onLikesChanged);
    _scrollController.addListener(_onScroll);
    _bootstrapFeed();
  }

  Future<void> _bootstrapFeed() async {
    final canOpenFeed = await _initializeFeedMode();
    if (!canOpenFeed || !mounted) {
      if (mounted) {
        setState(() => _isBootstrapping = false);
      }
      return;
    }
    await _loadInitial();
    if (mounted) {
      setState(() => _isBootstrapping = false);
    }
  }

  Future<bool> _initializeFeedMode() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return true;

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final userData = userDoc.data();
      final profileCompleted = userData?['profileCompleted'] == true;

      if (!profileCompleted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            context.go(AppRoutes.profile);
          }
        });
        return false;
      }

      if (mounted) {
        setState(() {
          _feedMode = 'reels';
        });
      }
      return true;
    } catch (_) {
      if (mounted) {
        setState(() {
          _feedMode = 'reels';
        });
      }
      return true;
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;

    final shouldShowTabs = position.pixels > 80;
    if (_showModeTabs != shouldShowTabs) {
      setState(() {
        _showModeTabs = shouldShowTabs;
      });
    }

    if (position.pixels >= position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  Future<void> _toggleFollowUser(String userId, bool isFollowing) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || userId.isEmpty || user.uid == userId) return;
    final docId = '${user.uid}_$userId';
    final ref =
        FirebaseFirestore.instance.collection('user_follows').doc(docId);
    try {
      if (isFollowing) {
        await ref.delete();
      } else {
        await ref.set({
          'followerId': user.uid,
          'followingId': userId,
          'createdAt': Timestamp.now(),
        });
      }
    } on FirebaseException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Follow update failed: ${e.message ?? e.code}')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Follow update failed'))),
      );
    }
  }

  Future<void> _loadInitial() async {
    setState(() {
      _posts.clear();
      _lastDoc = null;
      _followingFallbackLastDoc = null;
      _timelineLastDoc = null;
      _hasMore = true;
      _didJumpToPost = false;
      _inlineSuggestionsDismissed = false;
    });
    await _loadFollowingIds();
    await _loadViewedHighlights();
    await _loadMore();
  }

  Future<void> _loadFollowingIds() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _followingPageIds = [];
      _followingUserIds = [];
      return;
    }
    try {
      final snap = await FirebaseFirestore.instance
          .collection('page_follows')
          .where('followerId', isEqualTo: user.uid)
          .get();
      _followingPageIds = snap.docs
          .map((d) => (d.data())['pageId'] as String? ?? '')
          .where((id) => id.isNotEmpty)
          .toList();
      final userFollowSnap = await FirebaseFirestore.instance
          .collection('user_follows')
          .where('followerId', isEqualTo: user.uid)
          .get();
      _followingUserIds = userFollowSnap.docs
          .map((d) => (d.data())['followingId'] as String? ?? '')
          .where((id) => id.isNotEmpty)
          .toList();
    } catch (_) {
      _followingPageIds = [];
      _followingUserIds = [];
    }
  }

  Future<void> _loadViewedHighlights() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _viewedHighlightPosts.clear();
      return;
    }
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final rawMap = snap.data()?['highlightViews'];
      final viewedMap =
          rawMap is Map ? rawMap.cast<String, dynamic>() : <String, dynamic>{};
      _viewedHighlightPosts
        ..clear()
        ..addEntries(
          viewedMap.entries.map(
            (entry) => MapEntry(
              _creatorKeyFromStorage(entry.key),
              entry.value?.toString() ?? '',
            ),
          ),
        );
    } catch (_) {
      _viewedHighlightPosts.clear();
    }
  }

  Future<void> _markHighlightViewed(String creatorKey, String postId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'highlightViews': {
          _highlightStorageKey(creatorKey): postId,
        },
      }, SetOptions(merge: true));
    } catch (_) {
      // Keep the local viewed state even if persistence fails.
    }
  }

  Future<void> _loadMore() async {
    if (_isLoading || !_hasMore) return;
    setState(() {
      _isLoading = true;
    });
    try {
      // Phase 3: each tab asks Firestore exactly for what it shows.
      //  - Following: my own timeline list (filled by the server).
      //  - Reels: only video posts (hasVideo == true).
      //  - For You: highest trendingScore first (scored by the server).
      if (_feedMode == 'following') {
        final loaded = await _loadFollowingTimeline();
        // Old accounts whose timeline is still being filled: use the old way.
        if (!loaded &&
            _posts.isEmpty &&
            (_followingPageIds.isNotEmpty || _followingUserIds.isNotEmpty)) {
          _hasMore = true;
          await _loadFollowingFallback();
        }
      } else {
        final posts = FirebaseFirestore.instance.collection('posts');
        Query<Map<String, dynamic>> query = _feedMode == 'reels'
            ? posts
                .where('hasVideo', isEqualTo: true)
                .orderBy('createdAt', descending: true)
            : posts.orderBy('trendingScore', descending: true);
        query = query.limit(_pageSize);
        if (_lastDoc != null) {
          query = query.startAfterDocument(_lastDoc!);
        }
        final snap = await query.get();
        if (snap.docs.isNotEmpty) {
          _lastDoc = snap.docs.last;
          _appendPosts(snap.docs);
        }
        if (snap.docs.length < _pageSize) {
          _hasMore = false;
        }
      }
    } catch (e) {
      debugPrint('Failed to load feed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('Failed to load feed'))),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  DocumentSnapshot? _timelineLastDoc;

  /// Reads timelines/{me}/items (newest first), then the posts themselves.
  /// Returns false if the timeline had nothing at all.
  Future<bool> _loadFollowingTimeline() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      _hasMore = false;
      return false;
    }
    Query<Map<String, dynamic>> query = FirebaseFirestore.instance
        .collection('timelines')
        .doc(uid)
        .collection('items')
        .orderBy('createdAt', descending: true)
        .limit(_pageSize);
    if (_timelineLastDoc != null) {
      query = query.startAfterDocument(_timelineLastDoc!);
    }
    final items = await query.get();
    if (items.docs.length < _pageSize) _hasMore = false;
    if (items.docs.isEmpty) return _timelineLastDoc != null;
    _timelineLastDoc = items.docs.last;

    // Fetch the posts 30 at a time (Firestore's limit for whereIn).
    final ids = items.docs.map((d) => d.id).toList();
    final fetched = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    for (var i = 0; i < ids.length; i += 30) {
      final chunk = ids.sublist(i, i + 30 > ids.length ? ids.length : i + 30);
      final snap = await FirebaseFirestore.instance
          .collection('posts')
          .where(FieldPath.documentId, whereIn: chunk)
          .get();
      fetched.addAll(snap.docs);
    }
    _appendPosts(fetched); // deleted posts simply don't come back
    return true;
  }

  Future<void> _loadFollowingFallback() async {
    if (_followingPageIds.isEmpty && _followingUserIds.isEmpty) {
      _hasMore = false;
      return;
    }
    for (var attempt = 0; attempt < 5; attempt++) {
      Query<Map<String, dynamic>> query = FirebaseFirestore.instance
          .collection('posts')
          .orderBy('createdAt', descending: true)
          .limit(_pageSize);
      if (_followingFallbackLastDoc != null) {
        query = query.startAfterDocument(_followingFallbackLastDoc!);
      }
      final snap = await query.get();
      if (snap.docs.isEmpty) {
        _hasMore = false;
        return;
      }
      _followingFallbackLastDoc = snap.docs.last;
      final filtered = snap.docs
          .map((doc) => Post.fromFirestore(doc))
          .where(
            (post) =>
                _followingPageIds.contains(post.businessId) ||
                _followingUserIds.contains(post.ownerId),
          )
          .toList();
      if (filtered.isNotEmpty) {
        setState(() {
          final existingIds = _posts.map((p) => p.id).toSet();
          _posts.addAll(filtered.where((p) => !existingIds.contains(p.id)));
          _posts.sort(_comparePostsForDisplay);
        });
        if (filtered.length < _pageSize && snap.docs.length < _pageSize) {
          _hasMore = false;
        }
        return;
      }
    }
  }

  void _appendPosts(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    final existingIds = _posts.map((p) => p.id).toSet();
    final nextPosts = docs
        .map((doc) => Post.fromFirestore(doc))
        .where((post) => !existingIds.contains(post.id))
        .toList();
    if (nextPosts.isEmpty) return;
    setState(() {
      _posts.addAll(nextPosts);
      _posts.sort(_comparePostsForDisplay);
    });
  }

  int _comparePostsForDisplay(Post a, Post b) {
    final scoreCompare = _postScore(b).compareTo(_postScore(a));
    if (scoreCompare != 0) return scoreCompare;
    return b.createdAt.compareTo(a.createdAt);
  }

  double _postScore(Post post) {
    final ageHours = DateTime.now().difference(post.createdAt).inMinutes / 60;
    final freshnessBoost =
        ageHours <= 0 ? 3.0 : (72 - ageHours.clamp(0, 72)) / 24;
    final engagementBoost =
        (post.likeCount * 0.18) + (post.commentCount * 0.34);
    final mediaBoost = post.media.isNotEmpty ? 0.4 : 0.0;
    final relationshipBoost =
        (_followingUserIds.contains(post.ownerId) ? 2.6 : 0.0) +
            (_followingPageIds.contains(post.businessId) ? 2.2 : 0.0);
    final creatorLearningBoost =
        _creatorAffinity[_creatorKeyForPost(post)] ?? 0.0;
    final postLearningBoost = _postAffinity[post.id] ?? 0.0;
    return freshnessBoost +
        engagementBoost +
        mediaBoost +
        relationshipBoost +
        creatorLearningBoost +
        postLearningBoost;
  }

  void _toggleFeedMode(String mode) {
    if (_feedMode == mode) return;
    setState(() {
      _feedMode = mode;
    });
    _loadInitial();
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Widget _buildFeedModeTabs() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      height: 46,
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: isDark
            ? Colors.black.withValues(alpha: 0.28)
            : Colors.white.withValues(alpha: 0.58),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.22),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _FeedTabButton(
            label: tr('For You'),
            isActive: _feedMode == 'forYou',
            compact: true,
            onTap: () => _toggleFeedMode('forYou'),
          ),
          _FeedTabButton(
            label: tr('Reels'),
            isActive: _feedMode == 'reels',
            compact: true,
            onTap: () => _toggleFeedMode('reels'),
          ),
          _FeedTabButton(
            label: tr('Following'),
            isActive: _feedMode == 'following',
            compact: true,
            onTap: () => _toggleFeedMode('following'),
          ),
        ],
      ),
    );
  }

  Future<void> _refreshFeed() async {
    if (mounted) {
      setState(() => _isRefreshing = true);
    }
    try {
      await _loadInitial();
    } finally {
      if (mounted) {
        setState(() => _isRefreshing = false);
      }
    }
  }

  Future<void> _refreshAfterPostCreated(String postId) async {
    if (_feedMode != 'forYou') {
      setState(() => _feedMode = 'forYou');
    }
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
    await _refreshFeed();

    if (!mounted) return;
    final snapshot =
        await FirebaseFirestore.instance.collection('posts').doc(postId).get();
    if (!snapshot.exists || !mounted) return;

    final createdPost = Post.fromFirestore(snapshot);
    setState(() {
      _posts.removeWhere((post) => post.id == createdPost.id);
      _posts.insert(0, createdPost);
    });
  }

  String _creatorKeyForPost(Post post) {
    if (post.businessId.isNotEmpty) {
      return 'page:${post.businessId}';
    }
    return 'user:${post.ownerId}';
  }

  String _highlightStorageKey(String creatorKey) =>
      creatorKey.replaceAll(':', '__');

  String _creatorKeyFromStorage(String storageKey) =>
      storageKey.replaceAll('__', ':');

  void _recordFeedSignal(
    Post post, {
    double creatorDelta = 0,
    double postDelta = 0,
  }) {
    final creatorKey = _creatorKeyForPost(post);
    _creatorAffinity.update(
      creatorKey,
      (value) => value + creatorDelta,
      ifAbsent: () => creatorDelta,
    );
    _postAffinity.update(
      post.id,
      (value) => value + postDelta,
      ifAbsent: () => postDelta,
    );
  }

  void _registerImpression(Post post, double visibleFraction) {
    if (visibleFraction < 0.72) return;
    if (_impressedPosts.add(post.id)) {
      _incrementPostMetric(post.id, 'viewCount');
      _recordFeedSignal(
        post,
        creatorDelta: 0.18,
        postDelta: 0.35,
      );
    }
  }

  void _registerMediaEngagement(Post post, int mediaIndex) {
    final key = '${post.id}:$mediaIndex';
    if (_engagedMedia.add(key)) {
      final media = mediaIndex >= 0 && mediaIndex < post.media.length
          ? post.media[mediaIndex]
          : null;
      if (media?.isVideo == true) {
        _incrementPostMetric(post.id, 'playCount');
      }
      _recordFeedSignal(
        post,
        creatorDelta: media?.isVideo == true ? 0.5 : 0.22,
        postDelta: media?.isVideo == true ? 0.95 : 0.38,
      );
    }
  }

  void _replacePost(String postId, Post Function(Post current) transform) {
    final index = _posts.indexWhere((post) => post.id == postId);
    if (index < 0 || !mounted) return;
    setState(() {
      _posts[index] = transform(_posts[index]);
    });
  }

  // Changes only the number on screen; LikeStore.toggle (called right after
  // through _postsRepository.toggleLike) flips the heart and writes the like.
  void _optimisticallyToggleLike(Post post, String currentUserId) {
    final delta = LikeStore.instance.isLiked(post.id) ? -1 : 1;
    _replacePost(post.id, (current) {
      final next = current.likeCount + delta;
      return current.copyWith(likeCount: next < 0 ? 0 : next);
    });
  }

  Future<void> _submitComment(String postId, String content) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _replacePost(postId, (current) {
      return current.copyWith(commentCount: current.commentCount + 1);
    });

    await _postsRepository.addComment(postId, trimmed);
  }

  void _incrementPostMetricLocally(String postId, String field) {
    _replacePost(postId, (current) {
      return current.copyWith(
        viewCount:
            field == 'viewCount' ? current.viewCount + 1 : current.viewCount,
        playCount:
            field == 'playCount' ? current.playCount + 1 : current.playCount,
      );
    });
  }

  Future<void> _incrementPostMetric(String postId, String field) async {
    _incrementPostMetricLocally(postId, field);
    try {
      await FirebaseFirestore.instance.collection('posts').doc(postId).update({
        field: FieldValue.increment(1),
      });
    } catch (_) {}
  }

  void _scrollToPost(
    String postId,
    List<Post> visiblePosts,
    Map<String, GlobalObjectKey> postKeys,
  ) {
    final index = visiblePosts.indexWhere((p) => p.id == postId);
    if (index < 0) return;
    final key = postKeys[postId];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        alignment: 0.1,
      );
      return;
    }
    if (_scrollController.hasClients && visiblePosts.length > 1) {
      final ratio = index / (visiblePosts.length - 1);
      final target = _scrollController.position.maxScrollExtent * ratio;
      _scrollController.animateTo(
        target.clamp(0, _scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctxAfter = postKeys[postId]?.currentContext;
        if (ctxAfter != null) {
          Scrollable.ensureVisible(
            ctxAfter,
            duration: const Duration(milliseconds: 250),
            alignment: 0.1,
          );
        }
      });
    }
  }

  void _showCommentDialog(String postId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final bottomPadding = MediaQuery.of(context).viewInsets.bottom;
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Padding(
          padding: EdgeInsets.only(bottom: bottomPadding),
          child: Container(
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF141821) : Colors.white,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.2),
                  blurRadius: 20,
                  offset: const Offset(0, -4),
                ),
              ],
            ),
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 48,
                  height: 5,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white24 : Colors.black12,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.chat_bubble_outline),
                    const SizedBox(width: 8),
                    Text(
                      tr('Add a comment'),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _commentController,
                  minLines: 2,
                  maxLines: 5,
                  decoration: InputDecoration(
                    hintText: tr('Write something nice...'),
                    filled: true,
                    fillColor: isDark
                        ? Colors.white.withOpacity(0.06)
                        : Colors.black.withOpacity(0.04),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    TextButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        _commentController.clear();
                      },
                      child: Text(tr('Cancel')),
                    ),
                    const Spacer(),
                    ElevatedButton.icon(
                      onPressed: () async {
                        if (_commentController.text.trim().isNotEmpty) {
                          await _submitComment(
                            postId,
                            _commentController.text.trim(),
                          );
                          if (context.mounted) {
                            Navigator.of(context).pop();
                          }
                          _commentController.clear();
                        }
                      },
                      icon: const Icon(Icons.send),
                      label: Text(tr('Post')),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
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

  @override
  Widget build(BuildContext context) {
    final currentUser = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: const Padding(
          padding: EdgeInsets.only(left: 6),
          child: _AnimatedSpotlightWordmark(),
        ),
        actions: [
          ValueListenableBuilder<Timestamp?>(
            valueListenable: _badgeClearedAt,
            builder: (context, clearedAt, _) {
              // Phase 3: one small counter document kept by the server
              // (users_private/{uid}.unreadNotifications) instead of
              // downloading every unread notification just to count them.
              return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: currentUser == null
                    ? const Stream.empty()
                    : FirebaseFirestore.instance
                        .collection('users_private')
                        .doc(currentUser.uid)
                        .snapshots(),
                builder: (context, counterSnap) {
                  final serverCount =
                      (counterSnap.data?.data()?['unreadNotifications'] as num?)
                              ?.toInt() ??
                          0;
                  // Just opened the notifications: show 0 until the server
                  // catches up.
                  final count = clearedAt != null &&
                          DateTime.now()
                                  .difference(clearedAt.toDate())
                                  .inSeconds <
                              10
                      ? 0
                      : (serverCount < 0 ? 0 : serverCount);
                  {
                    return IconButton(
                      onPressed: () {
                        _badgeClearedAt.value = Timestamp.now();
                        unawaited(NotificationReadService.markAllRead()
                            .catchError((Object error) {
                          debugPrint(
                              'Could not clear notification badge: $error');
                        }));
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
                  }
                },
              );
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.person),
            onSelected: (value) {
              if (value == 'profile') {
                final uid = currentUser?.uid;
                if (uid != null) {
                  context.push(AppRoutes.clientProfilePath(uid));
                }
              } else if (value == 'settings') {
                context.push(AppRoutes.settings);
              } else if (value == 'logout') {
                _signOut();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                value: 'profile',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.person_outline),
                  title: Text(tr('Profile')),
                ),
              ),
              PopupMenuItem<String>(
                value: 'settings',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.settings_outlined),
                  title: Text(tr('Settings')),
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem<String>(
                value: 'logout',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.logout, color: Colors.redAccent),
                  title: Text(tr('Logout')),
                ),
              ),
            ],
          ),
        ],
      ),
      body: Builder(
        builder: (context) {
          final waitingForFeed =
              _isBootstrapping || (_isLoading && _posts.isEmpty);
          final posts = _posts;
          final screenWidth = MediaQuery.sizeOf(context).width;
          final isDesktopWide = screenWidth >= 1200;

          // Build reels content if in reels mode
          Widget? reelsContent;
          if (_feedMode == 'reels') {
            final reelPosts = posts
                .where((post) => post.media.any((item) => item.isVideo))
                .toList();
            if (reelPosts.isEmpty && !_isLoading) {
              reelsContent = Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.video_library, size: 64, color: AppColors.grey),
                    const SizedBox(height: 14),
                    Text(tr('No reels yet'), style: const TextStyle(fontSize: 18)),
                    const SizedBox(height: 6),
                    Text(tr('Video posts will appear here once creators upload.')),
                  ],
                ),
              );
            } else {
              // Download the next 2 reels while this one plays.
              void prefetchFrom(int index) {
                ReelPrefetcher.prefetch(
                  reelPosts
                      .skip(index + 1)
                      .take(2)
                      .map((p) => p.media.firstWhere((m) => m.isVideo).url),
                );
              }

              prefetchFrom(_reelsPageController.hasClients
                  ? (_reelsPageController.page ?? 0).round()
                  : 0);
              reelsContent = PageView.builder(
                controller: _reelsPageController,
                scrollDirection: Axis.vertical,
                itemCount: reelPosts.length,
                onPageChanged: prefetchFrom,
                itemBuilder: (context, index) {
                  final post = reelPosts[index];
                  final videoMedia = post.media.firstWhere((m) => m.isVideo);
                  final currentUserId =
                      FirebaseAuth.instance.currentUser?.uid ?? '';
                  final isLiked = LikeStore.instance.isLiked(post.id);
                  final isFollowingCreator = post.businessId.isNotEmpty
                      ? _followingPageIds.contains(post.businessId)
                      : _followingUserIds.contains(post.ownerId);
                  return GestureDetector(
                    onTap: () {
                      _recordFeedSignal(post,
                          creatorDelta: 0.45, postDelta: 0.9);
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => business_post.PostDetailPage(
                            post: post,
                            initialMediaIndex: 0,
                          ),
                        ),
                      );
                    },
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: _AutoPlayVideoPreview(
                            url: videoMedia.url,
                            height: MediaQuery.of(context).size.height,
                            rounded: false,
                            showReelLabel: true,
                            alwaysLoad: true,
                            onTap: () {},
                          ),
                        ),
                        Positioned(
                          left: 16,
                          bottom: 34,
                          right: 96,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                post.businessName.isNotEmpty
                                    ? post.businessName
                                    : 'Creator',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 17,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                post.content,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Positioned(
                          right: 12,
                          bottom: 40,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: Icon(
                                  isLiked
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  color: isLiked
                                      ? Colors.pinkAccent
                                      : Colors.white,
                                ),
                                onPressed: () {
                                  final uid = currentUserId;
                                  if (uid.isEmpty) return;
                                  _optimisticallyToggleLike(post, uid);
                                  _recordFeedSignal(
                                    post,
                                    creatorDelta: isLiked ? -0.15 : 0.6,
                                    postDelta: isLiked ? -0.25 : 1.25,
                                  );
                                  _postsRepository.toggleLike(post.id);
                                },
                              ),
                              Text('${post.likeCount}',
                                  style: const TextStyle(color: Colors.white)),
                              const SizedBox(height: 18),
                              IconButton(
                                icon: const Icon(Icons.chat_bubble_outline,
                                    color: Colors.white),
                                onPressed: () => _showCommentDialog(post.id),
                              ),
                              Text('${post.commentCount}',
                                  style: const TextStyle(color: Colors.white)),
                              const SizedBox(height: 18),
                              IconButton(
                                icon: const Icon(Icons.share,
                                    color: Colors.white),
                                onPressed: () => _sharePost(post),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            }
          }

          final filtered = posts;

          final latestHighlightPosts = <String, Post>{};
          for (final post in filtered) {
            final creatorKey = _creatorKeyForPost(post);
            latestHighlightPosts.putIfAbsent(creatorKey, () => post);
          }
          final followedHighlights = <Post>[];
          final affinityHighlights = <Post>[];
          final fallbackHighlights = <Post>[];
          for (final entry in latestHighlightPosts.entries) {
            final creatorKey = entry.key;
            final post = entry.value;
            if (currentUser != null && post.ownerId == currentUser.uid) {
              continue;
            }
            final isFollowed = post.businessId.isNotEmpty
                ? _followingPageIds.contains(post.businessId)
                : _followingUserIds.contains(post.ownerId);
            final affinity = _creatorAffinity[creatorKey] ?? 0;
            if (isFollowed) {
              followedHighlights.add(post);
            } else if (affinity >= 1.2) {
              affinityHighlights.add(post);
            } else {
              fallbackHighlights.add(post);
            }
          }
          int sortHighlights(Post a, Post b) {
            final aViewed =
                _viewedHighlightPosts[_creatorKeyForPost(a)] == a.id;
            final bViewed =
                _viewedHighlightPosts[_creatorKeyForPost(b)] == b.id;
            if (aViewed != bViewed) {
              return aViewed ? 1 : -1;
            }
            return b.createdAt.compareTo(a.createdAt);
          }

          followedHighlights.sort(sortHighlights);
          affinityHighlights.sort(sortHighlights);
          fallbackHighlights.sort(sortHighlights);

          final ownHighlight = currentUser == null
              ? null
              : filtered.cast<Post?>().firstWhere(
                    (post) => post?.ownerId == currentUser.uid,
                    orElse: () => null,
                  );
          final combinedHighlights = [
            ...followedHighlights,
            ...affinityHighlights,
            ...fallbackHighlights,
          ]..sort(sortHighlights);
          final highlightList = <Post>[
            if (ownHighlight != null) ownHighlight,
            ...combinedHighlights.where(
              (post) => ownHighlight == null || post.id != ownHighlight.id,
            ),
          ].take(10).toList();
          final suggestionCreators = <String, Post>{};
          for (final post in filtered) {
            if (currentUser != null && post.ownerId == currentUser.uid) {
              continue;
            }
            final alreadyFollowing = post.businessId.isNotEmpty
                ? _followingPageIds.contains(post.businessId)
                : _followingUserIds.contains(post.ownerId);
            if (alreadyFollowing) continue;
            final creatorKey = _creatorKeyForPost(post);
            if (!suggestionCreators.containsKey(creatorKey)) {
              suggestionCreators[creatorKey] = post;
            }
            if (suggestionCreators.length >= 6) break;
          }
          final suggestionList = suggestionCreators.values.toList();
          final hasInlineSuggestions = !_inlineSuggestionsDismissed &&
              suggestionList.isNotEmpty &&
              filtered.length >= 3;
          final suggestionIndex = hasInlineSuggestions ? 3 : -1;

          final postKeys = <String, GlobalObjectKey>{};
          final feedContent = Column(
            children: [
              if (_showModeTabs) _buildFeedModeTabs(),
              // Phase 4: Status (24h stories) replaces the old highlights row.
              const StatusBar(),
              Expanded(
                child: Stack(
                  children: [
                    if (waitingForFeed)
                      const Center(child: SpotlightLoader(size: 44))
                    else
                      RefreshIndicator(
                        color: AppColors.primary,
                        backgroundColor: Theme.of(context).cardColor,
                        displacement: 72,
                        onRefresh: _refreshFeed,
                        child: _isLoading && filtered.isEmpty
                            ? const _FeedShimmerList()
                            : ListView.builder(
                                controller: _scrollController,
                                physics: const AlwaysScrollableScrollPhysics(),
                                cacheExtent:
                                    2000, // Preload more items for smoother scrolling
                                itemCount: filtered.isEmpty
                                    ? 1
                                    : filtered.length +
                                        (hasInlineSuggestions ? 1 : 0) +
                                        (_hasMore ? 1 : 0),
                                itemBuilder: (context, index) {
                                  if (filtered.isEmpty) {
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 72,
                                        horizontal: 24,
                                      ),
                                      child: Center(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              Icons.post_add_rounded,
                                              size: 56,
                                              color: AppColors.grey,
                                            ),
                                            const SizedBox(height: 16),
                                            Text(
                                              _feedMode == 'following'
                                                  ? (_followingPageIds
                                                              .isEmpty &&
                                                          _followingUserIds
                                                              .isEmpty
                                                      ? 'You are not following anyone yet'
                                                      : 'No posts from creators you follow yet')
                                                  : 'No posts yet',
                                              textAlign: TextAlign.center,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .headlineSmall,
                                            ),
                                            const SizedBox(height: 8),
                                            Text(
                                              _feedMode == 'following'
                                                  ? 'Follow creators to see their posts here.'
                                                  : 'Follow creators to discover their posts, or create the first one.',
                                              textAlign: TextAlign.center,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodyMedium
                                                  ?.copyWith(
                                                    color: AppColors.grey,
                                                  ),
                                            ),
                                            const SizedBox(height: 18),
                                            FilledButton.icon(
                                              onPressed: _showCreateOptions,
                                              icon: const Icon(Icons.add),
                                              label:
                                                  Text(tr('Create a post')),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  }
                                  if (hasInlineSuggestions &&
                                      index == suggestionIndex) {
                                    return _InlineFollowSuggestionsCard(
                                      suggestions: suggestionList,
                                      onDismiss: () {
                                        HapticFeedback.selectionClick();
                                        setState(() {
                                          _inlineSuggestionsDismissed = true;
                                        });
                                      },
                                      onOpenCreator: (post) {
                                        if (post.businessId.isNotEmpty) {
                                          HapticFeedback.lightImpact();
                                          context.push(
                                            AppRoutes.businessProfilePath(
                                                post.businessId),
                                          );
                                        } else {
                                          HapticFeedback.lightImpact();
                                          context.push(
                                            AppRoutes.clientProfilePath(
                                                post.ownerId),
                                          );
                                        }
                                      },
                                      onFollow: (post) {
                                        if (post.businessId.isNotEmpty) {
                                          HapticFeedback.lightImpact();
                                          setState(() {
                                            if (!_followingPageIds
                                                .contains(post.businessId)) {
                                              _followingPageIds
                                                  .add(post.businessId);
                                            }
                                          });
                                          _toggleFollowPage(
                                              post.businessId, false);
                                        } else {
                                          HapticFeedback.lightImpact();
                                          setState(() {
                                            if (!_followingUserIds
                                                .contains(post.ownerId)) {
                                              _followingUserIds
                                                  .add(post.ownerId);
                                            }
                                          });
                                          _toggleFollowUser(
                                              post.ownerId, false);
                                        }
                                      },
                                    );
                                  }
                                  final postIndex = hasInlineSuggestions &&
                                          index > suggestionIndex
                                      ? index - 1
                                      : index;
                                  if (postIndex >= filtered.length) {
                                    return const Padding(
                                      padding:
                                          EdgeInsets.symmetric(vertical: 16),
                                      child: Center(
                                        child: CircularProgressIndicator(),
                                      ),
                                    );
                                  }
                                  final post = filtered[postIndex];
                                  final key = postKeys.putIfAbsent(
                                    post.id,
                                    () => GlobalObjectKey(post.id),
                                  );
                                  WidgetsBinding.instance
                                      .addPostFrameCallback((_) {
                                    if (!_didJumpToPost &&
                                        widget.initialPostId != null &&
                                        post.id == widget.initialPostId) {
                                      _didJumpToPost = true;
                                      final ctx = key.currentContext;
                                      if (ctx != null) {
                                        Scrollable.ensureVisible(
                                          ctx,
                                          duration:
                                              const Duration(milliseconds: 300),
                                          alignment: 0.1,
                                        );
                                      }
                                    }
                                  });

                                  final followDocStream = currentUser == null
                                      ? const Stream<DocumentSnapshot>.empty()
                                      : (post.businessId.isNotEmpty
                                          ? FirebaseFirestore.instance
                                              .collection('page_follows')
                                              .doc(
                                                  '${currentUser.uid}_${post.businessId}')
                                              .snapshots()
                                          : FirebaseFirestore.instance
                                              .collection('user_follows')
                                              .doc(
                                                  '${currentUser.uid}_${post.ownerId}')
                                              .snapshots());
                                  return StreamBuilder<DocumentSnapshot>(
                                    stream: followDocStream,
                                    builder: (context, followSnap) {
                                      final isFollowing =
                                          followSnap.data?.exists == true;
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
                                          final isSaved =
                                              favSnap.data?.exists == true;
                                          return VisibilityDetector(
                                            key: ValueKey(
                                                'feed_post_${post.id}'),
                                            onVisibilityChanged: (info) {
                                              _registerImpression(
                                                  post, info.visibleFraction);
                                            },
                                            child: PostCard(
                                              key: key,
                                              post: post,
                                              currentUserId:
                                                  currentUser?.uid ?? '',
                                              isSaved: isSaved,
                                              initialMediaIndex:
                                                  _mediaIndexByPostId[
                                                          post.id] ??
                                                      0,
                                              onMediaIndexChanged: (index) {
                                                _mediaIndexByPostId[post.id] =
                                                    index;
                                              },
                                              onMediaEngaged: (index) =>
                                                  _registerMediaEngagement(
                                                      post, index),
                                              onDoubleTapLike: () {
                                                final uid =
                                                    currentUser?.uid ?? '';
                                                final alreadyLiked = LikeStore
                                                    .instance
                                                    .isLiked(post.id);
                                                if (uid.isEmpty ||
                                                    alreadyLiked) {
                                                  return;
                                                }
                                                HapticFeedback.mediumImpact();
                                                _optimisticallyToggleLike(
                                                    post, uid);
                                                _recordFeedSignal(
                                                  post,
                                                  creatorDelta: 0.75,
                                                  postDelta: 1.45,
                                                );
                                                _postsRepository
                                                    .toggleLike(post.id);
                                              },
                                              onOpenDetail: (index) {
                                                HapticFeedback.selectionClick();
                                                _recordFeedSignal(
                                                  post,
                                                  creatorDelta: 0.45,
                                                  postDelta: 0.9,
                                                );
                                                Navigator.of(context).push(
                                                  MaterialPageRoute(
                                                    builder: (_) =>
                                                        business_post
                                                            .PostDetailPage(
                                                      post: post,
                                                      initialMediaIndex: index,
                                                    ),
                                                  ),
                                                );
                                              },
                                              onLike: () {
                                                final currentlyLiked = LikeStore
                                                    .instance
                                                    .isLiked(post.id);
                                                final uid =
                                                    currentUser?.uid ?? '';
                                                if (uid.isNotEmpty) {
                                                  HapticFeedback.lightImpact();
                                                  _optimisticallyToggleLike(
                                                      post, uid);
                                                }
                                                _recordFeedSignal(
                                                  post,
                                                  creatorDelta: currentlyLiked
                                                      ? -0.15
                                                      : 0.6,
                                                  postDelta: currentlyLiked
                                                      ? -0.25
                                                      : 1.25,
                                                );
                                                _postsRepository
                                                    .toggleLike(post.id);
                                              },
                                              onComment: () {
                                                HapticFeedback.selectionClick();
                                                _recordFeedSignal(
                                                  post,
                                                  creatorDelta: 0.7,
                                                  postDelta: 1.15,
                                                );
                                                _showCommentDialog(post.id);
                                              },
                                              onShare: () {
                                                HapticFeedback.selectionClick();
                                                _recordFeedSignal(
                                                  post,
                                                  creatorDelta: 0.42,
                                                  postDelta: 0.8,
                                                );
                                                _sharePost(post);
                                              },
                                              onLocationTap: () =>
                                                  _openLocation(post),
                                              onMessage: () {
                                                HapticFeedback.selectionClick();
                                                _recordFeedSignal(
                                                  post,
                                                  creatorDelta: 0.6,
                                                  postDelta: 0.75,
                                                );
                                                _startChat(post);
                                              },
                                              onSave: () {
                                                HapticFeedback.lightImpact();
                                                _recordFeedSignal(
                                                  post,
                                                  creatorDelta:
                                                      isSaved ? -0.12 : 0.75,
                                                  postDelta:
                                                      isSaved ? -0.2 : 1.2,
                                                );
                                                _toggleFavorite(post, isSaved);
                                              },
                                              isFollowingCreator: isFollowing,
                                              onFollowCreator: () {
                                                HapticFeedback.lightImpact();
                                                _recordFeedSignal(
                                                  post,
                                                  creatorDelta:
                                                      isFollowing ? -0.4 : 1.6,
                                                  postDelta:
                                                      isFollowing ? -0.2 : 0.35,
                                                );
                                                if (post
                                                    .businessId.isNotEmpty) {
                                                  _toggleFollowPage(
                                                      post.businessId,
                                                      isFollowing);
                                                } else {
                                                  _toggleFollowUser(
                                                      post.ownerId,
                                                      isFollowing);
                                                }
                                              },
                                              onEdit: () =>
                                                  _showEditDialog(post),
                                              onDelete: () =>
                                                  _confirmDelete(post),
                                            ),
                                          );
                                        },
                                      );
                                    },
                                  );
                                },
                              ),
                      ),
                    IgnorePointer(
                      child: SafeArea(
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: AnimatedSlide(
                            offset: _isRefreshing
                                ? Offset.zero
                                : const Offset(0, -1.4),
                            duration: const Duration(milliseconds: 260),
                            curve: Curves.easeOutCubic,
                            child: AnimatedOpacity(
                              opacity: _isRefreshing ? 1 : 0,
                              duration: const Duration(milliseconds: 200),
                              child: Container(
                                margin: const EdgeInsets.only(top: 8),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? const Color(0xFF141821)
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(999),
                                  boxShadow: [
                                    BoxShadow(
                                      color:
                                          Colors.black.withValues(alpha: 0.12),
                                      blurRadius: 20,
                                      offset: const Offset(0, 8),
                                    ),
                                  ],
                                ),
                                child: const _RefreshingSpotlightPill(),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );

          // Use reels content if in reels mode, otherwise use feed content
          final mainContent = reelsContent ?? feedContent;

          if (!isDesktopWide) {
            return mainContent;
          }

          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 20, 18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 92,
                  child: _DesktopSpotlightDock(
                    feedMode: _feedMode,
                    onSwitchFeed: () => _showFeedModePicker(),
                    onOpenDiscover: () => context.push(AppRoutes.search),
                    onOpenMessages: () => context.push(AppRoutes.chats),
                    onCreatePost: _showCreateOptions,
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                          maxWidth: _feedMode == 'reels' ? 640 : 920),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Theme.of(context).brightness == Brightness.dark
                              ? const Color(0xFF10141C)
                              : Colors.white.withValues(alpha: 0.94),
                          borderRadius: BorderRadius.circular(32),
                          border: Border.all(
                            color:
                                Theme.of(context).brightness == Brightness.dark
                                    ? Colors.white10
                                    : Colors.black.withValues(alpha: 0.06),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.10),
                              blurRadius: 28,
                              offset: const Offset(0, 14),
                            ),
                          ],
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: mainContent,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 18),
                SizedBox(
                  width: 300,
                  child: SingleChildScrollView(
                    child: _DesktopSpotlightRail(
                      feedMode: _feedMode,
                      followingCount:
                          _followingPageIds.length + _followingUserIds.length,
                      recommendedCreators: suggestionList,
                      onOpenCreator: (post) {
                        if (post.businessId.isNotEmpty) {
                          context.push(
                              AppRoutes.businessProfilePath(post.businessId));
                        } else {
                          context
                              .push(AppRoutes.clientProfilePath(post.ownerId));
                        }
                      },
                      onFollowCreator: (post) {
                        if (post.businessId.isNotEmpty) {
                          if (!_followingPageIds.contains(post.businessId)) {
                            setState(() {
                              _followingPageIds.add(post.businessId);
                            });
                          }
                          _toggleFollowPage(post.businessId, false);
                        } else {
                          if (!_followingUserIds.contains(post.ownerId)) {
                            setState(() {
                              _followingUserIds.add(post.ownerId);
                            });
                          }
                          _toggleFollowUser(post.ownerId, false);
                        }
                      },
                      onSwitchFeed: () => _showFeedModePicker(),
                      onOpenDiscover: () => context.push(AppRoutes.search),
                      onCreatePost: _showCreateOptions,
                      onOpenMessages: () => context.push(AppRoutes.chats),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.center,
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: Theme.of(context)
                        .colorScheme
                        .outlineVariant
                        .withValues(alpha: 0.55),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.10),
                      blurRadius: 20,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: _bottomNavigationItem(
                        icon: Icons.home_rounded,
                        label: tr('Home'),
                        selected: true,
                        onTap: () {
                          if (_feedMode != 'forYou') {
                            setState(() => _feedMode = 'forYou');
                          }
                          if (_scrollController.hasClients) {
                            _scrollController.jumpTo(0);
                          }
                          _refreshFeed();
                        },
                      ),
                    ),
                    Expanded(
                      child: _bottomNavigationItem(
                        icon: Icons.search_rounded,
                        label: tr('Discover'),
                        onTap: () => context.push(AppRoutes.search),
                      ),
                    ),
                    Expanded(
                      child: _bottomNavigationItem(
                        icon: Icons.add_rounded,
                        label: tr('Create'),
                        emphasized: true,
                        onTap: _showCreateOptions,
                      ),
                    ),
                    Expanded(
                      child: _bottomNavigationItem(
                        icon: Icons.message_rounded,
                        label: tr('Messages'),
                        onTap: () => context.push(AppRoutes.chats),
                      ),
                    ),
                    Expanded(
                      child: _bottomNavigationItem(
                        icon: Icons.person_rounded,
                        label: tr('Profile'),
                        onTap: currentUser == null
                            ? () => context.go(AppRoutes.profile)
                            : () => context.push(
                                  AppRoutes.clientProfilePath(
                                    currentUser.uid,
                                  ),
                                ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bottomNavigationItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool selected = false,
    bool emphasized = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final iconColor = emphasized
        ? scheme.onPrimary
        : selected
            ? scheme.primary
            : scheme.onSurfaceVariant;

    return Tooltip(
      message: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 38,
                  decoration: BoxDecoration(
                    color: emphasized
                        ? scheme.primary
                        : selected
                            ? scheme.primary.withValues(alpha: 0.12)
                            : Colors.transparent,
                    borderRadius: BorderRadius.circular(15),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    icon,
                    size: 22,
                    color: iconColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color:
                            selected ? scheme.primary : scheme.onSurfaceVariant,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showCreateOptions() async {
    HapticFeedback.selectionClick();
    final selected = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white24 : Colors.black26,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                Text(
                  tr('Create'),
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  tr('Choose what you want to publish.'),
                  style: const TextStyle(color: AppColors.grey),
                ),
                const SizedBox(height: 14),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const CircleAvatar(
                    backgroundColor: AppColors.primary,
                    child: Icon(Icons.post_add_rounded, color: Colors.white),
                  ),
                  title: Text(tr('Create post')),
                  subtitle: Text(tr('Share your next spotlight post')),
                  onTap: () => Navigator.of(context).pop('post'),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: AppColors.primary.withValues(alpha: 0.16),
                    child: const Icon(
                      Icons.storefront_rounded,
                      color: AppColors.primary,
                    ),
                  ),
                  title: Text(tr('Create page')),
                  subtitle: Text(tr('Set up a new creator or business page')),
                  onTap: () => Navigator.of(context).pop('page'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted || selected == null) return;
    if (selected == 'post') {
      final postId = await context.push<String>(AppRoutes.createPost);
      if (postId != null && mounted) {
        await _refreshAfterPostCreated(postId);
      }
    } else if (selected == 'page') {
      context.push(AppRoutes.businessSetup);
    }
  }

  Future<void> _showFeedModePicker() async {
    HapticFeedback.selectionClick();
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF101722)
                  : Theme.of(context).colorScheme.surface,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(26)),
              border: Border.all(
                color: isDark ? Colors.white10 : Colors.black12,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.25),
                  blurRadius: 20,
                  offset: const Offset(0, -6),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                Text(
                  tr('Duhuze Feed'),
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  tr('Pick the vibe you want to scroll right now.'),
                  style: const TextStyle(color: AppColors.grey),
                ),
                const SizedBox(height: 14),
                _feedModeTile(
                  context: context,
                  icon: Icons.auto_awesome,
                  title: tr('For You'),
                  subtitle: tr('Trending picks, fresh posts, and discovery energy'),
                  selected: _feedMode == 'forYou',
                  onTap: () => Navigator.of(context).pop('forYou'),
                ),
                const SizedBox(height: 8),
                _feedModeTile(
                  context: context,
                  icon: Icons.video_collection,
                  title: tr('Reels'),
                  subtitle: tr('Vertical scrolling video-only experience'),
                  selected: _feedMode == 'reels',
                  onTap: () => Navigator.of(context).pop('reels'),
                ),
                const SizedBox(height: 8),
                _feedModeTile(
                  context: context,
                  icon: Icons.favorite_border,
                  title: tr('Following'),
                  subtitle:
                      tr('Only the pages and creators you chose to keep up with'),
                  selected: _feedMode == 'following',
                  onTap: () => Navigator.of(context).pop('following'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (selected != null && selected != _feedMode) {
      _toggleFeedMode(selected);
    }
  }

  Widget _feedModeTile({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color:
          selected ? AppColors.primary.withOpacity(0.12) : Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected
                  ? AppColors.primary.withOpacity(0.35)
                  : Colors.white.withOpacity(0.08),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: selected
                      ? AppColors.primary.withOpacity(0.18)
                      : Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  icon,
                  color: selected ? AppColors.primary : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: AppColors.grey,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? AppColors.primary : Colors.transparent,
                  border: Border.all(
                    color: selected ? AppColors.primary : Colors.white24,
                  ),
                ),
                child: selected
                    ? const Icon(
                        Icons.check,
                        size: 15,
                        color: Colors.white,
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _sharePost(Post post) {
    HapticFeedback.selectionClick();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final isDark = Theme.of(sheetContext).brightness == Brightness.dark;
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
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
                Text(
                  tr('Share this post'),
                  style: Theme.of(sheetContext).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 6),
                _ShareSheetPreview(post: post),
                const SizedBox(height: 14),
                Text(
                  tr('Quick actions'),
                  style: Theme.of(sheetContext).textTheme.labelLarge?.copyWith(
                        color: AppColors.grey,
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _ShareSheetAction(
                      icon: Icons.copy_rounded,
                      label: tr('Copy text'),
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
                        Navigator.of(sheetContext).pop();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(tr('Caption copied'))),
                        );
                      },
                    ),
                    _ShareSheetAction(
                      icon: Icons.send_rounded,
                      label: tr('Send'),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        Navigator.of(sheetContext).pop();
                        _startChat(post);
                      },
                    ),
                    _ShareSheetAction(
                      icon: Icons.person_outline_rounded,
                      label: tr('Open creator'),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        Navigator.of(sheetContext).pop();
                        if (post.businessId.isNotEmpty) {
                          context.push(
                              AppRoutes.businessProfilePath(post.businessId));
                        } else {
                          context
                              .push(AppRoutes.clientProfilePath(post.ownerId));
                        }
                      },
                    ),
                    _ShareSheetAction(
                      icon: Icons.link_rounded,
                      label: tr('Copy ID'),
                      onTap: () async {
                        HapticFeedback.lightImpact();
                        await Clipboard.setData(ClipboardData(text: post.id));
                        if (!mounted) return;
                        Navigator.of(sheetContext).pop();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(tr('Post ID copied'))),
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

  void _openLocation(Post post) async {
    if (post.googleMapsLink != null && post.googleMapsLink!.isNotEmpty) {
      final Uri url = Uri.parse(post.googleMapsLink!);
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('Could not open Google Maps'))),
        );
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Location not available'))),
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
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          titlePadding: const EdgeInsets.only(top: 12),
          title: Center(child: Text(tr('Edit Post'))),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    hintText: tr('Update your post...'),
                    border: const OutlineInputBorder(),
                  ),
                  maxLines: 4,
                  maxLength: 300,
                ),
                const SizedBox(height: 12),
                if (!removeMedia &&
                    pickedImage == null &&
                    pickedVideo == null &&
                    post.media.isNotEmpty &&
                    !post.media.first.isVideo)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImage(
                      imageUrl: post.media.first.url,
                      height: 140,
                      width: double.infinity,
                      fit: BoxFit.cover,
                    ),
                  ),
                if (!removeMedia &&
                    pickedImage == null &&
                    pickedVideo == null &&
                    post.media.isNotEmpty &&
                    post.media.first.isVideo)
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
                        label: Text(tr('Pick image')),
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
                        label: Text(tr('Take photo')),
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
                        label: Text(tr('Pick video')),
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
                        label: Text(tr('Record video')),
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
                    label: Text(tr('Remove media')),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: Text(tr('Cancel')),
            ),
            ElevatedButton(
              onPressed: () async {
                final text = controller.text.trim();
                if (text.isEmpty) return;
                String? imageUrl = post.imageUrl;
                String? videoUrl = post.videoUrl;
                List<PostMedia>? mediaUpdate;
                if (removeMedia) {
                  imageUrl = null;
                  videoUrl = null;
                  mediaUpdate = [];
                } else if (pickedImage != null) {
                  imageUrl = await _uploadImage(pickedImage!);
                  videoUrl = null;
                  if (imageUrl == null) return;
                  mediaUpdate = [
                    PostMedia(type: PostMediaType.image, url: imageUrl),
                  ];
                } else if (pickedVideo != null) {
                  videoUrl = await _uploadVideo(pickedVideo!);
                  imageUrl = null;
                  if (videoUrl == null) return;
                  mediaUpdate = [
                    PostMedia(type: PostMediaType.video, url: videoUrl),
                  ];
                }
                final update = <String, dynamic>{
                  'content': text,
                  'imageUrl': imageUrl,
                  'videoUrl': videoUrl,
                  'updatedAt': Timestamp.now(),
                };
                if (mediaUpdate != null) {
                  update['media'] = mediaUpdate.map((m) => m.toMap()).toList();
                }
                await FirebaseFirestore.instance
                    .collection('posts')
                    .doc(post.id)
                    .update(update);
                if (mounted) {
                  Navigator.of(context).pop();
                }
              },
              child: Text(tr('Save')),
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
        title: Text(tr('Delete Post')),
        content: Text(tr('Are you sure you want to delete this post?')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('Cancel')),
          ),
          ElevatedButton(
            onPressed: () async {
              await _postsRepository.deletePost(post.id);
              if (mounted) {
                Navigator.of(context).pop();
              }
            },
            child: Text(tr('Delete')),
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
      return await R2StorageService.instance.uploadImage(
        bucket: 'post-images',
        path: path,
        bytes: bytes,
      );
    } catch (e) {
      debugPrint('Error uploading image: $e');
      return null;
    }
  }

  Future<String?> _uploadVideo(File originalFile) async {
    try {
      // Shrink to 720p on the phone first (Android/iOS).
      final videoFile = await VideoCompressor.compress(originalFile);
      final user = FirebaseAuth.instance.currentUser;
      final bytes = await videoFile.readAsBytes();
      final path =
          '${user?.uid ?? 'anon'}/${DateTime.now().millisecondsSinceEpoch}.mp4';
      return await R2StorageService.instance.uploadVideo(
        bucket: 'post-videos',
        path: path,
        bytes: bytes,
      );
    } catch (e) {
      debugPrint('Error uploading video: $e');
      return null;
    }
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
    if (post.businessId.isEmpty) {
      final chatId = await repo.createOrGetDirectChat(
        userAId: user.uid,
        userBId: post.ownerId,
      );
      if (!mounted) return;
      context.push(AppRoutes.chatDetailPath(chatId));
      return;
    }
    final chatId = await repo.createOrGetChat(
      businessId: post.businessId,
      businessOwnerId: post.ownerId,
      clientId: user.uid,
    );
    if (!mounted) return;
    context.push(AppRoutes.chatDetailPath(chatId));
  }
}

class _AutoPlayVideoPreview extends StatefulWidget {
  const _AutoPlayVideoPreview({
    required this.url,
    required this.onTap,
    this.height = 440,
    this.rounded = true,
    this.onDoubleTap,
    this.onActivePlayback,
    this.showReelLabel = false,
    this.alwaysLoad = false,
  });

  /// Reels load at once; feed videos wait for a tap in Lite mode.
  final bool alwaysLoad;
  final String url;
  final double height;
  final bool rounded;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onActivePlayback;
  final bool showReelLabel;

  @override
  State<_AutoPlayVideoPreview> createState() => _AutoPlayVideoPreviewState();
}

class _AutoPlayVideoPreviewState extends State<_AutoPlayVideoPreview> {
  static final ValueNotifier<bool> _globalMuted = ValueNotifier<bool>(true);
  static _AutoPlayVideoPreviewState? _activePreview;

  VideoPlayerController? _controller;
  Player? _mediaKitPlayer;
  VideoController? _mediaKitController;
  bool _initialized = false;
  bool _isVisible = false;
  bool _isMuted = true;
  bool _didNotifyActivePlayback = false;

  /// Lite mode: nothing is downloaded until the user taps play.
  late bool _waitForTap =
      !widget.alwaysLoad && LiteModeService.instance.enabled;

  void _startLoading() {
    if (Platform.isWindows) {
      _initMediaKit();
    } else {
      _initVideoPlayer();
    }
  }

  @override
  void initState() {
    super.initState();
    if (!_waitForTap) _startLoading();
    _isMuted = _globalMuted.value;
    _globalMuted.addListener(_handleGlobalMuteChanged);
  }

  Future<void> _initVideoPlayer() async {
    // Play from the phone if ReelPrefetcher already downloaded this reel.
    final cached = await ReelPrefetcher.cachedFile(widget.url);
    if (!mounted) return;
    _controller = (cached != null
        ? VideoPlayerController.file(cached)
        : VideoPlayerController.networkUrl(Uri.parse(widget.url)))
      ..initialize().then((_) {
        if (mounted) {
          setState(() => _initialized = true);
          _controller?.setLooping(true);
          _controller?.setVolume(_globalMuted.value ? 0 : 1);
          if (_isVisible) _activatePlayback();
        }
      });
  }

  void _initMediaKit() async {
    _mediaKitPlayer = Player();
    _mediaKitController = VideoController(_mediaKitPlayer!);
    try {
      await _mediaKitPlayer!.open(Media(widget.url), play: false);
      _mediaKitPlayer!.setPlaylistMode(PlaylistMode.loop);
      if (mounted) {
        setState(() => _initialized = true);
        _mediaKitPlayer!.setVolume(_globalMuted.value ? 0 : 100);
        if (_isVisible) _activatePlayback();
      }
    } catch (e) {
      // Handle error silently
    }
  }

  @override
  void dispose() {
    if (identical(_activePreview, this)) _activePreview = null;
    unawaited(_pausePlayback());
    if (Platform.isWindows) {
      _mediaKitPlayer?.dispose();
    } else {
      _controller?.dispose();
    }
    _globalMuted.removeListener(_handleGlobalMuteChanged);
    super.dispose();
  }

  void _activatePlayback() {
    if (!mounted || !_initialized) return;
    if (!identical(_activePreview, this)) {
      final previous = _activePreview;
      _activePreview = this;
      if (previous != null) unawaited(previous._pausePlayback());
    }
    unawaited(_playback());
  }

  void _deactivatePlayback() {
    _isVisible = false;
    if (identical(_activePreview, this)) _activePreview = null;
    unawaited(_pausePlayback());
  }

  Future<void> _playback() async {
    if (!mounted || !identical(_activePreview, this)) return;
    if (Platform.isWindows) {
      final player = _mediaKitPlayer;
      if (player == null) return;
      await player.play();
      if (!mounted || !identical(_activePreview, this)) {
        await player.pause();
        return;
      }
      await player.setVolume(_globalMuted.value ? 0 : 100);
      return;
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    await controller.play();
    if (!mounted || !identical(_activePreview, this)) {
      await controller.pause();
      return;
    }
    await controller.setVolume(_globalMuted.value ? 0 : 1);
  }

  Future<void> _pausePlayback() async {
    if (Platform.isWindows) {
      await _mediaKitPlayer?.pause();
      return;
    }
    final controller = _controller;
    if (controller?.value.isInitialized ?? false) {
      await controller!.pause();
    }
  }

  void _handleGlobalMuteChanged() {
    final nextMuted = _globalMuted.value;
    if (_isMuted == nextMuted) return;
    _isMuted = nextMuted;
    if (Platform.isWindows) {
      _mediaKitPlayer?.setVolume(nextMuted ? 0 : 100);
    } else {
      if (_controller?.value.isInitialized ?? false) {
        _controller!.setVolume(nextMuted ? 0 : 1);
      }
    }
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_waitForTap) {
      return GestureDetector(
        onTap: () {
          setState(() => _waitForTap = false);
          _isVisible = true;
          _startLoading();
        },
        child: Container(
          height: widget.height,
          decoration: BoxDecoration(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(widget.rounded ? 18 : 0),
          ),
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 64),
              const SizedBox(height: 8),
              Text(tr('Tap to play · Lite mode'),
                  style: const TextStyle(color: Colors.white70)),
            ],
          ),
        ),
      );
    }
    final controller = _controller;
    return VisibilityDetector(
      key: ObjectKey(this),
      onVisibilityChanged: (info) {
        _isVisible = info.visibleFraction >= 0.8;
        if (_isVisible) {
          if (!_didNotifyActivePlayback) {
            _didNotifyActivePlayback = true;
            widget.onActivePlayback?.call();
          }
          _activatePlayback();
        } else {
          _deactivatePlayback();
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        onLongPressStart: (_) {
          unawaited(_pausePlayback());
          if (mounted) {
            setState(() {});
          }
        },
        onLongPressEnd: (_) {
          if (_isVisible) _activatePlayback();
          if (mounted) {
            setState(() {});
          }
        },
        child: Container(
          height: widget.height,
          width: double.infinity,
          decoration: BoxDecoration(
            color: AppColors.lightGrey,
            borderRadius:
                widget.rounded ? BorderRadius.circular(8) : BorderRadius.zero,
          ),
          child: _initialized
              ? ClipRRect(
                  borderRadius: widget.rounded
                      ? BorderRadius.circular(8)
                      : BorderRadius.zero,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: IgnorePointer(
                          ignoring: true,
                          child: Platform.isWindows
                              ? Video(controller: _mediaKitController!)
                              : FittedBox(
                                  fit: BoxFit.cover,
                                  child: SizedBox(
                                    width: _controller!.value.size.width,
                                    height: _controller!.value.size.height,
                                    child: VideoPlayer(_controller!),
                                  ),
                                ),
                        ),
                      ),
                      Positioned(
                        left: 12,
                        top: 12,
                        child: Row(
                          children: [
                            _VideoMetaBadge(
                              icon: Platform.isWindows
                                  ? (_mediaKitPlayer!.state.playing
                                      ? Icons.play_circle_fill_rounded
                                      : Icons.pause_circle_filled_rounded)
                                  : (_controller!.value.isPlaying
                                      ? Icons.play_circle_fill_rounded
                                      : Icons.pause_circle_filled_rounded),
                            ),
                            if (widget.showReelLabel) ...[
                              const SizedBox(width: 8),
                              const _VideoMetaBadge(
                                icon: Icons.movie_creation_outlined,
                              ),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  tr('REEL'),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ]
                          ],
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(10, 34, 10, 10),
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Color(0xAA000000),
                              ],
                            ),
                          ),
                          child: Column(
                            children: [
                              if (!Platform.isWindows)
                                VideoProgressIndicator(
                                  _controller!,
                                  allowScrubbing: true,
                                  colors: VideoProgressColors(
                                    playedColor:
                                        Theme.of(context).colorScheme.primary,
                                    bufferedColor: Colors.white24,
                                    backgroundColor: Colors.white10,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        right: 4,
                        top: 4,
                        child: IconButton(
                          icon: Icon(
                            _isMuted ? Icons.volume_off : Icons.volume_up,
                            color: Colors.white,
                          ),
                          onPressed: () {
                            HapticFeedback.selectionClick();
                            _globalMuted.value = !_globalMuted.value;
                          },
                        ),
                      ),
                    ],
                  ),
                )
              : const Center(
                  child: Icon(Icons.play_circle_fill, size: 48),
                ),
        ),
      ),
    );
  }
}

class _PostMediaCarousel extends StatefulWidget {
  final List<PostMedia> media;
  final int initialIndex;
  final ValueChanged<int> onIndexChanged;
  final ValueChanged<int> onTap;
  final ValueChanged<int>? onMediaEngaged;
  final VoidCallback? onDoubleTapLike;
  final String? overlayText;

  const _PostMediaCarousel({
    required this.media,
    required this.initialIndex,
    required this.onIndexChanged,
    required this.onTap,
    this.onMediaEngaged,
    this.onDoubleTapLike,
    this.overlayText,
  });

  @override
  State<_PostMediaCarousel> createState() => _PostMediaCarouselState();
}

class _PostMediaCarouselState extends State<_PostMediaCarousel> {
  late final PageController _controller;
  late int _index;
  bool _showLikeBurst = false;

  void _triggerLikeBurst() {
    setState(() => _showLikeBurst = true);
    Future.delayed(const Duration(milliseconds: 620), () {
      if (!mounted) return;
      setState(() => _showLikeBurst = false);
    });
  }

  @override
  void initState() {
    super.initState();
    final safeIndex = widget.media.isEmpty
        ? 0
        : widget.initialIndex.clamp(0, widget.media.length - 1);
    _index = safeIndex;
    _controller = PageController(initialPage: safeIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _PostMediaCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.media.isEmpty) return;
    final maxIndex = widget.media.length - 1;
    if (_index > maxIndex) {
      _index = maxIndex;
      _controller.jumpToPage(_index);
      widget.onIndexChanged(_index);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.media.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      children: [
        SizedBox(
          height: 440,
          child: Stack(
            children: [
              PageView.builder(
                controller: _controller,
                itemCount: widget.media.length,
                onPageChanged: (value) {
                  setState(() => _index = value);
                  widget.onIndexChanged(value);
                },
                itemBuilder: (context, index) {
                  final item = widget.media[index];
                  if (item.isVideo) {
                    return _AutoPlayVideoPreview(
                      url: item.url,
                      onActivePlayback: () =>
                          widget.onMediaEngaged?.call(index),
                      onDoubleTap: () {
                        widget.onDoubleTapLike?.call();
                        _triggerLikeBurst();
                      },
                      onTap: () => widget.onTap(index),
                    );
                  }
                  return GestureDetector(
                    onDoubleTap: () {
                      widget.onDoubleTapLike?.call();
                      _triggerLikeBurst();
                    },
                    onTap: () => widget.onTap(index),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: CachedNetworkImage(
                        imageUrl: item.url,
                        height: 440,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => Container(
                          height: 440,
                          color: AppColors.lightGrey,
                          child:
                              const Center(child: CircularProgressIndicator()),
                        ),
                        errorWidget: (context, url, error) => Container(
                          height: 440,
                          color: AppColors.lightGrey,
                          child: const Icon(Icons.error),
                        ),
                      ),
                    ),
                  );
                },
              ),
              if (widget.overlayText != null &&
                  widget.overlayText!.trim().isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(12, 24, 12, 10),
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
                      widget.overlayText!,
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
              IgnorePointer(
                child: Center(
                  child: AnimatedOpacity(
                    opacity: _showLikeBurst ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(
                        begin: _showLikeBurst ? 0.76 : 1,
                        end: _showLikeBurst ? 1.12 : 0.76,
                      ),
                      duration: const Duration(milliseconds: 360),
                      curve: Curves.easeOutBack,
                      builder: (context, scale, child) {
                        return Transform.scale(scale: scale, child: child);
                      },
                      child: Container(
                        width: 94,
                        height: 94,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.18),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.favorite,
                          color: Colors.white,
                          size: 48,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (widget.media.length > 1) ...[
          const SizedBox(height: 8),
          SmoothPageIndicator(
            controller: _controller,
            count: widget.media.length,
            effect: const WormEffect(
              dotHeight: 6,
              dotWidth: 6,
              activeDotColor: AppColors.primary,
            ),
          ),
        ],
      ],
    );
  }
}

class _Shimmer extends StatefulWidget {
  const _Shimmer({required this.child});

  final Widget child;

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).brightness == Brightness.dark
        ? Colors.white12
        : Colors.black12;
    final highlight = Theme.of(context).brightness == Brightness.dark
        ? Colors.white24
        : Colors.black26;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return ShaderMask(
          shaderCallback: (bounds) {
            return LinearGradient(
              begin: Alignment(-1.0 - _controller.value, -0.3),
              end: Alignment(1.0 + _controller.value, 0.3),
              colors: [base, highlight, base],
              stops: const [0.2, 0.5, 0.8],
            ).createShader(bounds);
          },
          blendMode: BlendMode.srcATop,
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

class _FeedShimmerList extends StatelessWidget {
  const _FeedShimmerList();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: 5,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index == 0) {
          return const _HighlightRowSkeleton();
        }
        return const _PostCardSkeleton();
      },
    );
  }
}

class _HighlightRowSkeleton extends StatelessWidget {
  const _HighlightRowSkeleton();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 112,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
        scrollDirection: Axis.horizontal,
        itemCount: 5,
        separatorBuilder: (_, __) => const SizedBox(width: 14),
        itemBuilder: (context, index) {
          return _Shimmer(
            child: SizedBox(
              width: 84,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: const BoxDecoration(
                      color: Colors.grey,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: 64,
                    height: 10,
                    decoration: BoxDecoration(
                      color: Theme.of(context).cardColor,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PostCardSkeleton extends StatelessWidget {
  const _PostCardSkeleton();

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).cardColor;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: _Shimmer(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const CircleAvatar(radius: 20, backgroundColor: Colors.grey),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Container(
                      height: 12,
                      decoration: BoxDecoration(
                        color: surface,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    width: 48,
                    height: 10,
                    decoration: BoxDecoration(
                      color: surface,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                height: 320,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: surface,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: surface,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 32,
                    height: 10,
                    decoration: BoxDecoration(
                      color: surface,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: surface,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 32,
                    height: 10,
                    decoration: BoxDecoration(
                      color: surface,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  const Spacer(),
                  Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: surface,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RefreshingSpotlightPill extends StatefulWidget {
  const _RefreshingSpotlightPill();

  @override
  State<_RefreshingSpotlightPill> createState() =>
      _RefreshingSpotlightPillState();
}

class _RefreshingSpotlightPillState extends State<_RefreshingSpotlightPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return Transform.rotate(
              angle: _controller.value * 6.28318,
              child: child,
            );
          },
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: const Icon(
              Icons.auto_awesome_rounded,
              color: AppColors.primary,
              size: 14,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          tr('Refreshing'),
          style: const TextStyle(
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _InlineFollowSuggestionsCard extends StatelessWidget {
  final List<Post> suggestions;
  final VoidCallback onDismiss;
  final ValueChanged<Post> onOpenCreator;
  final ValueChanged<Post> onFollow;

  const _InlineFollowSuggestionsCard({
    required this.suggestions,
    required this.onDismiss,
    required this.onOpenCreator,
    required this.onFollow,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF151A24) : Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isDark ? Colors.white10 : Colors.black12,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('Suggested follows'),
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tr('Fresh creators and pages for you'),
                      style: const TextStyle(
                        color: AppColors.grey,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: onDismiss,
                icon: const Icon(Icons.close_rounded),
                tooltip: tr('Dismiss suggestions'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 164,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: suggestions.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final post = suggestions[index];
                final isPage = post.businessId.isNotEmpty;
                return GestureDetector(
                  onTap: () => onOpenCreator(post),
                  child: SizedBox(
                    width: 108,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          radius: 28,
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
                                  post.businessName.isNotEmpty
                                      ? post.businessName[0].toUpperCase()
                                      : '?',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                )
                              : null,
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          height: 32,
                          child: Text(
                            post.businessName,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                              height: 1.2,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          isPage ? 'Page' : 'Profile',
                          style: const TextStyle(
                            color: AppColors.grey,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 30,
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: () => onFollow(post),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(30),
                              maximumSize: const Size(double.infinity, 30),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              textStyle: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                            child: Text(tr('Follow')),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class PostCard extends StatelessWidget {
  final Post post;
  final String currentUserId;
  final int initialMediaIndex;
  final ValueChanged<int> onMediaIndexChanged;
  final ValueChanged<int>? onMediaEngaged;
  final ValueChanged<int> onOpenDetail;
  final VoidCallback? onDoubleTapLike;
  final VoidCallback onLike;
  final VoidCallback onComment;
  final VoidCallback onShare;
  final VoidCallback onLocationTap;
  final VoidCallback onMessage;
  final bool isSaved;
  final VoidCallback onSave;
  final bool isFollowingCreator;
  final VoidCallback onFollowCreator;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const PostCard({
    super.key,
    required this.post,
    required this.currentUserId,
    required this.initialMediaIndex,
    required this.onMediaIndexChanged,
    this.onMediaEngaged,
    required this.onOpenDetail,
    this.onDoubleTapLike,
    required this.onLike,
    required this.onComment,
    required this.onShare,
    required this.onLocationTap,
    required this.onMessage,
    required this.isSaved,
    required this.onSave,
    required this.isFollowingCreator,
    required this.onFollowCreator,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isLiked = LikeStore.instance.isLiked(post.id);
    final timeAgo = _formatTimeAgo(post.createdAt);
    final media = post.media;
    final isProfilePost = post.businessId.isEmpty;
    final hasVideo = media.any((item) => item.isVideo);
    const contentPadding = EdgeInsets.fromLTRB(14, 14, 14, 12);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onOpenDetail(initialMediaIndex),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: contentPadding,
                  child: Row(
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
                            Row(
                              children: [
                                GestureDetector(
                                  onTap: () {
                                    if (post.businessId.isNotEmpty) {
                                      context.push(
                                        AppRoutes.businessProfilePath(
                                          post.businessId,
                                        ),
                                      );
                                    } else {
                                      context.push(
                                        AppRoutes.clientProfilePath(
                                          post.ownerId,
                                        ),
                                      );
                                    }
                                  },
                                  child: Text(
                                    post.businessName.isNotEmpty
                                        ? post.businessName
                                        : 'Unknown Creator',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isProfilePost
                                        ? AppColors.primary
                                            .withValues(alpha: 0.1)
                                        : Colors.orange.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        isProfilePost
                                            ? Icons.person_outline_rounded
                                            : Icons.campaign_outlined,
                                        size: 11,
                                        color: isProfilePost
                                            ? AppColors.primary
                                            : Colors.orange.shade700,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        isProfilePost ? 'Profile' : 'Page',
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          color: isProfilePost
                                              ? AppColors.primary
                                              : Colors.orange.shade700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            Row(
                              children: [
                                Text(
                                  timeAgo,
                                  style: const TextStyle(
                                    color: AppColors.grey,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                if (post.ownerId != currentUserId)
                                  GestureDetector(
                                    onTap: onFollowCreator,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.black
                                            .withValues(alpha: 0.06),
                                        borderRadius:
                                            BorderRadius.circular(999),
                                        border: Border.all(
                                          color: isFollowingCreator
                                              ? AppColors.primary
                                                  .withValues(alpha: 0.4)
                                              : AppColors.grey
                                                  .withValues(alpha: 0.4),
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            isFollowingCreator
                                                ? Icons.verified
                                                : Icons.add,
                                            size: 12,
                                            color: isFollowingCreator
                                                ? AppColors.primary
                                                : AppColors.grey,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            isFollowingCreator
                                                ? 'Following'
                                                : (isProfilePost
                                                    ? 'Connect'
                                                    : 'Follow'),
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: isFollowingCreator
                                                  ? AppColors.primary
                                                  : AppColors.grey,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                const Spacer(),
                              ],
                            ),
                          ],
                        ),
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
                          itemBuilder: (context) => [
                            PopupMenuItem(
                              value: 'edit',
                              child: Text(tr('Edit')),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text(tr('Delete')),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                if (media.isNotEmpty) ...[
                  _PostMediaCarousel(
                    media: media,
                    initialIndex: initialMediaIndex,
                    onIndexChanged: onMediaIndexChanged,
                    onTap: onOpenDetail,
                    onMediaEngaged: onMediaEngaged,
                    onDoubleTapLike: onDoubleTapLike,
                    overlayText: post.content,
                  ),
                ] else ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
                    child: Text(
                      post.content,
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                  child: Row(
                    children: [
                      _AnimatedActionIcon(
                        active: isLiked,
                        onPressed: onLike,
                        burstOnActivate: true,
                        burstColor: Colors.pinkAccent,
                        child: Icon(
                          isLiked ? Icons.favorite : Icons.favorite_border,
                          color: isLiked ? Colors.pinkAccent : null,
                        ),
                      ),
                      _AnimatedCountText(value: post.likeCount),
                      const SizedBox(width: 6),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.all(4),
                        constraints: const BoxConstraints.tightFor(
                            width: 32, height: 32),
                        icon: const Icon(Icons.chat_bubble_outline),
                        onPressed: onComment,
                      ),
                      _AnimatedCountText(value: post.commentCount),
                      const SizedBox(width: 6),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.all(4),
                        constraints: const BoxConstraints.tightFor(
                            width: 32, height: 32),
                        icon: const Icon(Icons.forward),
                        onPressed: onShare,
                      ),
                      if (hasVideo)
                        Padding(
                          padding: const EdgeInsets.only(left: 2, right: 4),
                          child: _PostMetaChip(
                            icon: Icons.play_arrow_rounded,
                            label: _formatCompactMetric(post.playCount),
                            accent: Colors.pinkAccent,
                          ),
                        ),
                      const Spacer(),
                      if (post.googleMapsLink != null &&
                          post.googleMapsLink!.isNotEmpty)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.all(4),
                          constraints: const BoxConstraints.tightFor(
                              width: 32, height: 32),
                          icon: const Icon(Icons.location_on),
                          onPressed: onLocationTap,
                          tooltip: tr('Open location'),
                        ),
                      _AnimatedActionIcon(
                        active: isSaved,
                        onPressed: onSave,
                        child: Icon(
                          isSaved ? Icons.bookmark : Icons.bookmark_border,
                          color: isSaved ? AppColors.primary : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (post.ownerId != currentUserId)
              Positioned(
                right: 6,
                top: 6,
                child: IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: onMessage,
                  tooltip: tr('Message creator'),
                ),
              ),
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

String _formatCompactMetric(int value) {
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

class _PostMetaChip extends StatelessWidget {
  const _PostMetaChip({
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _VideoMetaBadge extends StatelessWidget {
  const _VideoMetaBadge({
    required this.icon,
  });

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white),
        ],
      ),
    );
  }
}

class _FeedTabButton extends StatelessWidget {
  const _FeedTabButton({
    required this.label,
    required this.onTap,
    required this.isActive,
    this.compact = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool isActive;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 11 : 12,
          vertical: compact ? 6 : 9,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(compact ? 13 : 16),
          color: isActive
              ? AppColors.primary
              : Theme.of(context).colorScheme.surface.withValues(alpha: 0.22),
          border: Border.all(
            color: isActive
                ? AppColors.primary
                : Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.12),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: compact ? 12 : 14,
            color: isActive
                ? Colors.white
                : Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

class _ShareSheetPreview extends StatelessWidget {
  const _ShareSheetPreview({required this.post});

  final Post post;

  @override
  Widget build(BuildContext context) {
    final thumb = post.media.isNotEmpty ? post.media.first.url : null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              width: 58,
              height: 58,
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
                  post.businessName.isNotEmpty ? post.businessName : 'Creator',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  post.content.trim().isEmpty
                      ? 'Share this moment with your people.'
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
    );
  }
}

class _AnimatedSpotlightWordmark extends StatefulWidget {
  const _AnimatedSpotlightWordmark();

  @override
  State<_AnimatedSpotlightWordmark> createState() =>
      _AnimatedSpotlightWordmarkState();
}

class _AnimatedSpotlightWordmarkState extends State<_AnimatedSpotlightWordmark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shineController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _shineController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _shineController,
      builder: (context, _) {
        final offset = -1.5 + (_shineController.value * 3);
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment(offset, 0),
            end: Alignment(offset + 1.4, 0),
            colors: const [
              Colors.white70,
              Colors.white,
              Color(0xFF61D1ED),
              Colors.white,
            ],
            stops: const [0, 0.38, 0.56, 1],
          ).createShader(bounds),
          child: Text(
            tr('Duhuze'),
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              letterSpacing: -0.35,
              fontSize: 21,
            ),
          ),
        );
      },
    );
  }
}

class _DesktopSpotlightRail extends StatelessWidget {
  const _DesktopSpotlightRail({
    required this.feedMode,
    required this.followingCount,
    required this.recommendedCreators,
    required this.onOpenCreator,
    required this.onFollowCreator,
    required this.onSwitchFeed,
    required this.onOpenDiscover,
    required this.onCreatePost,
    required this.onOpenMessages,
  });

  final String feedMode;
  final int followingCount;
  final List<Post> recommendedCreators;
  final void Function(Post) onOpenCreator;
  final void Function(Post) onFollowCreator;
  final VoidCallback onSwitchFeed;
  final VoidCallback onOpenDiscover;
  final VoidCallback onCreatePost;
  final VoidCallback onOpenMessages;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DesktopRailCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr('Duhuze on desktop'),
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                tr('A wider social view for your feed, conversations, and creator flow.'),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.grey,
                    ),
              ),
              const SizedBox(height: 14),
              _DesktopRailAction(
                icon: feedMode == 'reels'
                    ? Icons.video_collection
                    : Icons.dynamic_feed_rounded,
                title: feedMode == 'reels'
                    ? 'Reels feed'
                    : feedMode == 'following'
                        ? 'Following feed'
                        : 'For You feed',
                subtitle: feedMode == 'reels'
                    ? 'All video posts, vertical swipe experience.'
                    : (followingCount == 0
                        ? 'Long-press home anytime to switch feed mode.'
                        : 'Tracking $followingCount followed creators and pages.'),
                onTap: onSwitchFeed,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (feedMode == 'reels')
          _DesktopRailCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('Reels tuned for you'),
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Text(
                  tr('Swipe through short videos, and stay in flow. New reels refresh automatically.'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppColors.grey,
                      ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: onOpenMessages,
                      icon: const Icon(Icons.chat_bubble_outline),
                      label: Text(tr('Inbox')),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: onOpenDiscover,
                      icon: const Icon(Icons.notifications_none),
                      label: Text(tr('Updates')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        const SizedBox(height: 14),
        _DesktopRailCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr('Follow recommendations'),
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              if (recommendedCreators.isEmpty)
                Text(
                  tr('No recommendations yet. Check again in a moment.'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppColors.grey,
                      ),
                )
              else
                Column(
                  children: recommendedCreators
                      .take(5)
                      .map((post) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            child: Row(
                              children: [
                                ClipOval(
                                  child: SizedBox(
                                    width: 36,
                                    height: 36,
                                    child: post.businessImageUrl != null &&
                                            post.businessImageUrl!.isNotEmpty
                                        ? CachedNetworkImage(
                                            imageUrl: post.businessImageUrl!,
                                            fit: BoxFit.cover,
                                          )
                                        : Container(
                                            color: AppColors.lightGrey,
                                            child: Center(
                                              child: Text(
                                                post.businessName.isNotEmpty
                                                    ? post.businessName[0]
                                                        .toUpperCase()
                                                    : '?',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                          ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: GestureDetector(
                                    onTap: () => onOpenCreator(post),
                                    child: Text(
                                      post.businessName.isNotEmpty
                                          ? post.businessName
                                          : 'Creator',
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SizedBox(
                                  height: 30,
                                  child: FilledButton(
                                    onPressed: () => onFollowCreator(post),
                                    child: Text(tr('Follow')),
                                  ),
                                ),
                              ],
                            ),
                          ))
                      .toList(),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DesktopSpotlightDock extends StatelessWidget {
  const _DesktopSpotlightDock({
    required this.feedMode,
    required this.onSwitchFeed,
    required this.onOpenDiscover,
    required this.onOpenMessages,
    required this.onCreatePost,
  });

  final String feedMode;
  final VoidCallback onSwitchFeed;
  final VoidCallback onOpenDiscover;
  final VoidCallback onOpenMessages;
  final VoidCallback onCreatePost;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF131923)
            : Colors.white.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.06),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 22,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        children: [
          SizedBox(
            width: 54,
            height: 54,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Image.asset(
                'assets/images/duhuze_logo.png',
                fit: BoxFit.cover,
              ),
            ),
          ),
          const SizedBox(height: 16),
          _DesktopDockButton(
            icon: feedMode == 'following'
                ? Icons.people_alt_rounded
                : feedMode == 'reels'
                    ? Icons.video_collection
                    : Icons.home_rounded,
            label: feedMode == 'following'
                ? 'Following'
                : feedMode == 'reels'
                    ? 'Reels'
                    : 'For You',
            active: true,
            onTap: onSwitchFeed,
          ),
          const SizedBox(height: 10),
          _DesktopDockButton(
            icon: Icons.travel_explore_rounded,
            label: tr('Discover'),
            onTap: onOpenDiscover,
          ),
          const SizedBox(height: 10),
          _DesktopDockButton(
            icon: Icons.chat_bubble_rounded,
            label: tr('Inbox'),
            onTap: onOpenMessages,
          ),
          const Spacer(),
          _DesktopDockButton(
            icon: Icons.add_box_rounded,
            label: tr('Create'),
            active: true,
            filled: true,
            onTap: onCreatePost,
          ),
        ],
      ),
    );
  }
}

class _DesktopDockButton extends StatefulWidget {
  const _DesktopDockButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.filled = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final bool filled;

  @override
  State<_DesktopDockButton> createState() => _DesktopDockButtonState();
}

class _DesktopDockButtonState extends State<_DesktopDockButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final highlight = widget.active || _hovered;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          decoration: BoxDecoration(
            color: widget.filled
                ? AppColors.primary
                : highlight
                    ? AppColors.primary.withValues(alpha: isDark ? 0.18 : 0.12)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            children: [
              Icon(
                widget.icon,
                color: widget.filled
                    ? Colors.white
                    : highlight
                        ? AppColors.primary
                        : (isDark ? Colors.white70 : Colors.black54),
                size: 22,
              ),
              const SizedBox(height: 6),
              Text(
                widget.label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: widget.filled
                      ? Colors.white
                      : highlight
                          ? AppColors.primary
                          : (isDark ? Colors.white70 : Colors.black54),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopRailCard extends StatelessWidget {
  const _DesktopRailCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(
              alpha:
                  Theme.of(context).brightness == Brightness.dark ? 0.32 : 0.55,
            ),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: child,
    );
  }
}

class _DesktopRailAction extends StatefulWidget {
  const _DesktopRailAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  State<_DesktopRailAction> createState() => _DesktopRailActionState();
}

class _DesktopRailActionState extends State<_DesktopRailAction> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: _hovered
              ? AppColors.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(widget.icon, color: AppColors.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.subtitle,
                          style: const TextStyle(
                            color: AppColors.grey,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.arrow_forward_ios_rounded, size: 14),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShareSheetAction extends StatelessWidget {
  const _ShareSheetAction({
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

class _AnimatedCountText extends StatelessWidget {
  final int value;

  const _AnimatedCountText({required this.value});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.22),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );
      },
      child: Text(
        '$value',
        key: ValueKey(value),
      ),
    );
  }
}

class _AnimatedActionIcon extends StatefulWidget {
  final bool active;
  final VoidCallback onPressed;
  final Widget child;
  final bool burstOnActivate;
  final Color burstColor;

  const _AnimatedActionIcon({
    required this.active,
    required this.onPressed,
    required this.child,
    this.burstOnActivate = false,
    this.burstColor = Colors.pinkAccent,
  });

  @override
  State<_AnimatedActionIcon> createState() => _AnimatedActionIconState();
}

class _AnimatedActionIconState extends State<_AnimatedActionIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _burstController;
  late final Animation<double> _burstScale;
  late final Animation<double> _burstOpacity;

  @override
  void initState() {
    super.initState();
    _burstController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _burstScale = CurvedAnimation(
      parent: _burstController,
      curve: Curves.easeOutBack,
    );
    _burstOpacity = Tween<double>(begin: 0.9, end: 0).animate(
      CurvedAnimation(parent: _burstController, curve: Curves.easeOut),
    );
  }

  @override
  void didUpdateWidget(covariant _AnimatedActionIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.burstOnActivate && !oldWidget.active && widget.active) {
      _burstController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _burstController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      onPressed: widget.onPressed,
      icon: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          if (widget.burstOnActivate)
            IgnorePointer(
              child: AnimatedBuilder(
                animation: _burstController,
                builder: (context, _) {
                  if (_burstController.value == 0) {
                    return const SizedBox.shrink();
                  }
                  final scale = 0.7 + (_burstScale.value * 0.9);
                  final rise = 8 + (_burstScale.value * 14);
                  return Opacity(
                    opacity: _burstOpacity.value,
                    child: Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.none,
                      children: [
                        Transform.translate(
                          offset: Offset(-12, -rise),
                          child: Transform.scale(
                            scale: scale * 0.55,
                            child: Icon(
                              Icons.favorite,
                              color: widget.burstColor,
                            ),
                          ),
                        ),
                        Transform.translate(
                          offset: Offset(0, -rise - 4),
                          child: Transform.scale(
                            scale: scale * 0.72,
                            child: Icon(
                              Icons.favorite,
                              color: widget.burstColor.withValues(alpha: 0.9),
                            ),
                          ),
                        ),
                        Transform.translate(
                          offset: Offset(12, -rise),
                          child: Transform.scale(
                            scale: scale * 0.55,
                            child: Icon(
                              Icons.favorite,
                              color: widget.burstColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          TweenAnimationBuilder<double>(
            key: ValueKey(widget.active),
            tween: Tween<double>(begin: 0.68, end: 1),
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutBack,
            builder: (context, scale, iconChild) {
              return Transform.scale(
                scale: scale,
                child: iconChild,
              );
            },
            child: widget.child,
          ),
        ],
      ),
    );
  }
}
