import 'package:flutter/material.dart';
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
import 'dart:io';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/colors.dart';
import '../../../data/models/post_model.dart';
import '../../../data/repositories/posts_repository.dart';
import '../../../data/repositories/chat_repository.dart';
import '../../../core/services/supabase_storage_service.dart';
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
  final Map<String, int> _mediaIndexByPostId = {};
  static const int _pageSize = 10;
  final List<Post> _posts = [];
  DocumentSnapshot? _lastDoc;
  bool _isLoading = false;
  bool _hasMore = true;
  String _feedMode = 'forYou';
  List<String> _followingPageIds = [];
  List<List<String>> _followingChunks = [];
  List<DocumentSnapshot?> _chunkLastDocs = [];
  DocumentSnapshot? _followingFallbackLastDoc;
  int _currentFollowChunk = 0;
  bool _markingNotifications = false;
  final ValueNotifier<Timestamp?> _badgeClearedAt =
      ValueNotifier<Timestamp?>(null);
  bool _didJumpToPost = false;

  Future<void> _signOut() async {
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
        const SnackBar(content: Text('Follow update failed')),
      );
    }
  }

  @override
  void dispose() {
    _commentController.dispose();
    _scrollController.dispose();
    _badgeClearedAt.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadInitial();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  Future<void> _loadInitial() async {
    setState(() {
      _posts.clear();
      _lastDoc = null;
      _followingFallbackLastDoc = null;
      _hasMore = true;
      _didJumpToPost = false;
    });
    if (_feedMode == 'following') {
      await _loadFollowingIds();
    }
    await _loadMore();
  }

  Future<void> _loadFollowingIds() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _followingPageIds = [];
      _followingChunks = [];
      _chunkLastDocs = [];
      _currentFollowChunk = 0;
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
      _prepareFollowingChunks(_followingPageIds);
    } catch (_) {
      _followingPageIds = [];
      _followingChunks = [];
      _chunkLastDocs = [];
      _currentFollowChunk = 0;
    }
  }

  void _prepareFollowingChunks(List<String> ids) {
    _followingChunks = [];
    for (var i = 0; i < ids.length; i += 10) {
      final end = (i + 10) > ids.length ? ids.length : i + 10;
      _followingChunks.add(ids.sublist(i, end));
    }
    _chunkLastDocs =
        List<DocumentSnapshot?>.filled(_followingChunks.length, null);
    _currentFollowChunk = 0;
  }

  Future<void> _loadMore() async {
    if (_isLoading || !_hasMore) return;
    setState(() {
      _isLoading = true;
    });
    try {
      if (_feedMode == 'following') {
        if (_followingChunks.isEmpty) {
          if (mounted) {
            setState(() {
              _hasMore = false;
            });
          } else {
            _hasMore = false;
          }
          return;
        }
        while (true) {
          if (_currentFollowChunk >= _followingChunks.length) {
            _hasMore = false;
            break;
          }
          final chunk = _followingChunks[_currentFollowChunk];
          Query<Map<String, dynamic>> query = FirebaseFirestore.instance
              .collection('posts')
              .where('businessId', whereIn: chunk)
              .orderBy('createdAt', descending: true)
              .limit(_pageSize);
          final lastDoc = _chunkLastDocs[_currentFollowChunk];
          if (lastDoc != null) {
            query = query.startAfterDocument(lastDoc);
          }
          QuerySnapshot<Map<String, dynamic>> snap;
          try {
            snap = await query.get();
          } on FirebaseException catch (e) {
            final msg = (e.message ?? '').toLowerCase();
            if (e.code == 'failed-precondition' || msg.contains('index')) {
              await _loadFollowingFallback();
              return;
            }
            rethrow;
          }
          if (snap.docs.isEmpty) {
            _currentFollowChunk++;
            continue;
          }
          _chunkLastDocs[_currentFollowChunk] = snap.docs.last;
          _appendPosts(snap.docs);
          if (snap.docs.length < _pageSize) {
            _currentFollowChunk++;
          }
          break;
        }
      } else {
        Query<Map<String, dynamic>> query = FirebaseFirestore.instance
            .collection('posts')
            .orderBy('createdAt', descending: true)
            .limit(_pageSize);
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
          const SnackBar(content: Text('Failed to load feed')),
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

  Future<void> _loadFollowingFallback() async {
    if (_followingPageIds.isEmpty) {
      _hasMore = false;
      return;
    }
    for (var attempt = 0; attempt < 3; attempt++) {
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
          .where((post) => _followingPageIds.contains(post.businessId))
          .toList();
      if (filtered.isNotEmpty) {
        setState(() {
          _posts.addAll(
            filtered.where((p) => !_posts.any((e) => e.id == p.id)),
          );
        });
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
    });
  }

  void _toggleFeedMode(String mode) {
    if (_feedMode == mode) return;
    setState(() {
      _feedMode = mode;
    });
    _loadInitial();
  }

  Future<void> _refreshFeed() async {
    await _loadInitial();
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
      final target =
          _scrollController.position.maxScrollExtent * ratio;
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
                      'Add a comment',
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
                    hintText: 'Write something nice...',
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
                      child: const Text('Cancel'),
                    ),
                    const Spacer(),
                    ElevatedButton.icon(
                      onPressed: () async {
                        if (_commentController.text.trim().isNotEmpty) {
                          await _postsRepository.addComment(
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
                      label: const Text('Post'),
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
        titleSpacing: 12,
        title: const Padding(
          padding: EdgeInsets.only(left: 6),
          child: Text('Spotlight'),
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
            itemBuilder: (context) => const [
              PopupMenuItem<String>(
                value: 'profile',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.person_outline),
                  title: Text('Profile'),
                ),
              ),
              PopupMenuItem<String>(
                value: 'settings',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.settings_outlined),
                  title: Text('Settings'),
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem<String>(
                value: 'logout',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.logout, color: Colors.redAccent),
                  title: Text('Logout'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: Builder(
        builder: (context) {
          if (_isLoading && _posts.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }

          final posts = _posts;
          final filtered = posts;

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

          if (posts.isEmpty && !_isLoading) {
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
                    _feedMode == 'following'
                        ? (_followingPageIds.isEmpty
                            ? 'You are not following anyone yet'
                            : 'No posts from creators you follow yet')
                        : 'No posts yet',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _feedMode == 'following'
                        ? (_followingPageIds.isEmpty
                            ? 'Follow creators to see their posts here'
                            : 'They’ll show up here when they post')
                        : 'Follow creators to see their posts here',
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
                        onTap: () => _scrollToPost(
                          post.id,
                          filtered,
                          postKeys,
                        ),
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
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _refreshFeed,
                  child: _isLoading && filtered.isEmpty
                      ? const _FeedShimmerList()
                      : ListView.builder(
                          controller: _scrollController,
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: filtered.isEmpty
                              ? 1
                              : filtered.length + (_hasMore ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (filtered.isEmpty) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(
                                    vertical: 24, horizontal: 16),
                                child: Center(
                                  child: Text('No posts yet'),
                                ),
                              );
                            }
                            if (index >= filtered.length) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 16),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              );
                            }
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

              final followDocStream = currentUser == null || post.businessId.isEmpty
                  ? const Stream<DocumentSnapshot>.empty()
                  : FirebaseFirestore.instance
                      .collection('page_follows')
                      .doc('${currentUser.uid}_${post.businessId}')
                      .snapshots();
              return StreamBuilder<DocumentSnapshot>(
                stream: followDocStream,
                builder: (context, followSnap) {
                  final isFollowing = followSnap.data?.exists == true;
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
                        initialMediaIndex: _mediaIndexByPostId[post.id] ?? 0,
                        onMediaIndexChanged: (index) {
                          _mediaIndexByPostId[post.id] = index;
                        },
                    onOpenDetail: (index) {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => business_post.PostDetailPage(
                            post: post,
                            initialMediaIndex: index,
                          ),
                        ),
                      );
                    },
                        onLike: () => _postsRepository.toggleLike(post.id),
                        onComment: () => _showCommentDialog(post.id),
                        onShare: () => _sharePost(post),
                        onLocationTap: () => _openLocation(post),
                        onMessage: () => _startChat(post),
                        onSave: () => _toggleFavorite(post, isSaved),
                        isFollowingPage: isFollowing,
                        onFollowPage: () =>
                            _toggleFollowPage(post.businessId, isFollowing),
                        onEdit: () => _showEditDialog(post),
                        onDelete: () => _confirmDelete(post),
                      );
                    },
                  );
                },
              );
                          },
                        ),
                ),
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: StreamBuilder<DocumentSnapshot>(
          stream: currentUser == null
              ? const Stream.empty()
              : FirebaseFirestore.instance
                  .collection('users')
                  .doc(currentUser.uid)
                  .snapshots(),
          builder: (context, userSnap) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _roundActionButton(
                    icon: Icons.home,
                    tooltip: 'Home',
                    onTap: () => context.go(AppRoutes.feed),
                    onLongPress: _showFeedModePicker,
                  ),
                  const SizedBox(width: 16),
                  _roundActionButton(
                    icon: Icons.search,
                    tooltip: 'Discover',
                    onTap: () => context.push(AppRoutes.search),
                  ),
                  const SizedBox(width: 16),
                  _roundActionButton(
                    icon: Icons.add,
                    tooltip: 'Add post',
                    filled: true,
                    onTap: () => context.push(AppRoutes.createPost),
                  ),
                  const SizedBox(width: 16),
                  _roundActionButton(
                    icon: Icons.message,
                    tooltip: 'Messages',
                    onTap: () => context.push(AppRoutes.chats),
                  ),
                  const SizedBox(width: 16),
                  _roundActionButton(
                    icon: Icons.directions_car_filled_rounded,
                    tooltip: 'Traffic',
                    onTap: () => context.push(AppRoutes.trafficManagement),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _roundActionButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    bool filled = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: filled ? scheme.primary : scheme.surface,
        shape: const CircleBorder(),
        elevation: filled ? 4 : 1,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Icon(
              icon,
              color: filled ? scheme.onPrimary : scheme.onSurface,
            ),
          ),
        ),
      ),
    );
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
              color: isDark ? const Color(0xFF101722) : Theme.of(context).colorScheme.surface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
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
                  'Spotlight Feed',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Pick the vibe you want to scroll right now.',
                  style: TextStyle(color: AppColors.grey),
                ),
                const SizedBox(height: 14),
                _feedModeTile(
                  context: context,
                  icon: Icons.auto_awesome,
                  title: 'For You',
                  subtitle: 'Trending picks, fresh posts, and discovery energy',
                  selected: _feedMode == 'forYou',
                  onTap: () => Navigator.of(context).pop('forYou'),
                ),
                const SizedBox(height: 8),
                _feedModeTile(
                  context: context,
                  icon: Icons.favorite_border,
                  title: 'Following',
                  subtitle: 'Only the pages and creators you chose to keep up with',
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
      color: selected
          ? AppColors.primary.withOpacity(0.12)
          : Colors.transparent,
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


class _AutoPlayVideoPreview extends StatefulWidget {
  const _AutoPlayVideoPreview({required this.url, required this.onTap});

  final String url;
  final VoidCallback onTap;

  @override
  State<_AutoPlayVideoPreview> createState() => _AutoPlayVideoPreviewState();
}

class _AutoPlayVideoPreviewState extends State<_AutoPlayVideoPreview> {
  static final ValueNotifier<bool> _globalMuted =
      ValueNotifier<bool>(true);

  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _isMuted = true;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) {
        if (mounted) {
          setState(() => _initialized = true);
          _controller?.setVolume(_globalMuted.value ? 0 : 1);
        }
      });
    _isMuted = _globalMuted.value;
    _globalMuted.addListener(_handleGlobalMuteChanged);
  }

  @override
  void dispose() {
    _controller?.dispose();
    _globalMuted.removeListener(_handleGlobalMuteChanged);
    super.dispose();
  }

  void _handleGlobalMuteChanged() {
    final controller = _controller;
    if (controller == null) return;
    final nextMuted = _globalMuted.value;
    if (_isMuted == nextMuted) return;
    _isMuted = nextMuted;
    if (controller.value.isInitialized) {
      controller.setVolume(nextMuted ? 0 : 1);
    }
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return VisibilityDetector(
      key: ValueKey('video_${widget.url}'),
      onVisibilityChanged: (info) {
        if (controller == null) return;
        if (!controller.value.isInitialized) return;
        if (info.visibleFraction >= 0.6) {
          controller.play();
          controller.setVolume(_globalMuted.value ? 0 : 1);
        } else {
          controller.pause();
        }
      },
      child: InkWell(
        onTap: widget.onTap,
        child: Container(
          height: 440,
          width: double.infinity,
          decoration: BoxDecoration(
            color: AppColors.lightGrey,
            borderRadius: BorderRadius.circular(8),
          ),
          child: _initialized && controller != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: AspectRatio(
                          aspectRatio: controller.value.aspectRatio,
                          child: VideoPlayer(controller),
                        ),
                      ),
                      Positioned(
                        left: 8,
                        right: 8,
                        bottom: 6,
                        child: VideoProgressIndicator(
                          controller,
                          allowScrubbing: true,
                          colors: VideoProgressColors(
                            playedColor:
                                Theme.of(context).colorScheme.primary,
                            bufferedColor: Colors.white24,
                            backgroundColor: Colors.white10,
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
  final String? overlayText;

  const _PostMediaCarousel({
    required this.media,
    required this.initialIndex,
    required this.onIndexChanged,
    required this.onTap,
    this.overlayText,
  });

  @override
  State<_PostMediaCarousel> createState() => _PostMediaCarouselState();
}

class _PostMediaCarouselState extends State<_PostMediaCarousel> {
  late final PageController _controller;
  late int _index;

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
                      onTap: () => widget.onTap(index),
                    );
                  }
                  return GestureDetector(
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
                          child: const Center(
                              child: CircularProgressIndicator()),
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
      itemCount: 4,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        return const _PostCardSkeleton();
      },
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
                height: 220,
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
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PostCard extends StatelessWidget {
  final Post post;
  final String currentUserId;
  final int initialMediaIndex;
  final ValueChanged<int> onMediaIndexChanged;
  final ValueChanged<int> onOpenDetail;
  final VoidCallback onLike;
  final VoidCallback onComment;
  final VoidCallback onShare;
  final VoidCallback onLocationTap;
  final VoidCallback onMessage;
  final bool isSaved;
  final VoidCallback onSave;
  final bool isFollowingPage;
  final VoidCallback onFollowPage;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const PostCard({
    super.key,
    required this.post,
    required this.currentUserId,
    required this.initialMediaIndex,
    required this.onMediaIndexChanged,
    required this.onOpenDetail,
    required this.onLike,
    required this.onComment,
    required this.onShare,
    required this.onLocationTap,
    required this.onMessage,
    required this.isSaved,
    required this.onSave,
    required this.isFollowingPage,
    required this.onFollowPage,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isLiked = post.likes.contains(currentUserId);
    final timeAgo = _formatTimeAgo(post.createdAt);
    final media = post.media;
    const contentPadding = EdgeInsets.fromLTRB(14, 14, 14, 12);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      clipBehavior: Clip.antiAlias,
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
                                  onTap: onFollowPage,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withOpacity(0.06),
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(
                                        color: isFollowingPage
                                            ? AppColors.primary
                                                .withOpacity(0.4)
                                            : AppColors.grey
                                                .withOpacity(0.4),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          isFollowingPage
                                              ? Icons.verified
                                              : Icons.add,
                                          size: 12,
                                          color: isFollowingPage
                                              ? AppColors.primary
                                              : AppColors.grey,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          isFollowingPage
                                              ? 'Following'
                                              : 'Follow',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: isFollowingPage
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
              ),
              if (media.isNotEmpty) ...[
                _PostMediaCarousel(
                  media: media,
                  initialIndex: initialMediaIndex,
                  onIndexChanged: onMediaIndexChanged,
                  onTap: onOpenDetail,
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
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        isLiked ? Icons.favorite : Icons.favorite_border,
                        color: isLiked ? Colors.pinkAccent : null,
                      ),
                      onPressed: onLike,
                    ),
                    Text('${post.likes.length}'),
                    const SizedBox(width: 16),
                    IconButton(
                      icon: const Icon(Icons.chat_bubble_outline),
                      onPressed: onComment,
                    ),
                    Text('${post.comments.length}'),
                    const SizedBox(width: 16),
                    IconButton(
                      icon: const Icon(Icons.forward),
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
                tooltip: 'Message creator',
              ),
            ),
        ],
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
