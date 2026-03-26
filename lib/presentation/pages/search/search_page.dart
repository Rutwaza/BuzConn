import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/social_notification_service.dart';
import '../../../core/theme/colors.dart';
import '../../../data/models/post_model.dart';

enum SearchFilter { all, businesses, users, posts }

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  SearchFilter _filter = SearchFilter.all;
  final _currentUserId = FirebaseAuth.instance.currentUser?.uid;
  final ScrollController _resultsScrollController = ScrollController();
  final ScrollController _postScrollController = ScrollController();
  static const int _postPageSize = 10;
  static const int _resultPageSize = 10;
  final List<Post> _postResults = [];
  DocumentSnapshot? _postLastDoc;
  bool _isLoadingPosts = false;
  bool _hasMorePosts = true;
  String _lastPostQuery = '';
  final List<Map<String, dynamic>> _businessResults = [];
  final List<Map<String, dynamic>> _userResults = [];
  DocumentSnapshot? _businessLastDoc;
  DocumentSnapshot? _userLastDoc;
  bool _isLoadingBusinesses = false;
  bool _isLoadingUsers = false;
  bool _hasMoreBusinesses = true;
  bool _hasMoreUsers = true;
  bool _businessOrderByName = true;
  String _lastResultQuery = '';
  SearchFilter _lastResultFilter = SearchFilter.all;

  @override
  void dispose() {
    _controller.dispose();
    _resultsScrollController.dispose();
    _postScrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _postScrollController.addListener(_onPostScroll);
    _resultsScrollController.addListener(_onResultsScroll);
  }

  void _onPostScroll() {
    if (!_postScrollController.hasClients) return;
    final position = _postScrollController.position;
    if (position.pixels >= position.maxScrollExtent - 300) {
      _loadMorePosts();
    }
  }

  Future<void> _ensurePostsLoaded(String query) async {
    if (_filter != SearchFilter.posts && _filter != SearchFilter.all) return;
    if (_lastPostQuery == query && _postResults.isNotEmpty) return;
    _lastPostQuery = query;
    _postResults.clear();
    _postLastDoc = null;
    _hasMorePosts = true;
    await _loadMorePosts();
  }

  void _onResultsScroll() {
    if (!_resultsScrollController.hasClients) return;
    final position = _resultsScrollController.position;
    if (position.pixels >= position.maxScrollExtent - 300) {
      _loadMoreResults();
    }
  }

  Future<void> _ensureResultsLoaded(String query) async {
    if (_filter == SearchFilter.posts) return;
    if (_lastResultQuery == query &&
        _lastResultFilter == _filter &&
        (_businessResults.isNotEmpty || _userResults.isNotEmpty)) {
      return;
    }
    _lastResultQuery = query;
    _lastResultFilter = _filter;
    _businessResults.clear();
    _userResults.clear();
    _businessLastDoc = null;
    _userLastDoc = null;
    _hasMoreBusinesses = true;
    _hasMoreUsers = true;
    _businessOrderByName = true;
    await _loadMoreResults();
  }

  Future<void> _loadMoreResults() async {
    if (_filter == SearchFilter.posts) return;
    if (_filter == SearchFilter.businesses || _filter == SearchFilter.all) {
      await _loadMoreBusinesses();
    }
    if (_filter == SearchFilter.users || _filter == SearchFilter.all) {
      await _loadMoreUsers();
    }
    if (_filter == SearchFilter.all) {
      await _loadMorePosts();
    }
  }

  Future<void> _loadMoreBusinesses() async {
    if (_isLoadingBusinesses || !_hasMoreBusinesses) return;
    setState(() {
      _isLoadingBusinesses = true;
    });
    try {
      Query<Map<String, dynamic>> query;
      if (_businessOrderByName) {
        query = FirebaseFirestore.instance
            .collection('businesses')
            .where('isActive', isEqualTo: true)
            .orderBy('name')
            .limit(_resultPageSize);
      } else {
        query = FirebaseFirestore.instance
            .collection('businesses')
            .where('isActive', isEqualTo: true)
            .orderBy(FieldPath.documentId)
            .limit(_resultPageSize);
      }
      if (_businessLastDoc != null) {
        query = query.startAfterDocument(_businessLastDoc!);
      }
      QuerySnapshot<Map<String, dynamic>> snap;
      try {
        snap = await query.get();
      } on FirebaseException catch (e) {
        final msg = (e.message ?? '').toLowerCase();
        if (e.code == 'failed-precondition' || msg.contains('index')) {
          _businessOrderByName = false;
          _businessLastDoc = null;
          return _loadMoreBusinesses();
        }
        rethrow;
      }
      if (snap.docs.isNotEmpty) {
        _businessLastDoc = snap.docs.last;
        _businessResults.addAll(
          snap.docs.map((d) {
            final data = d.data();
            return {...data, 'id': d.id};
          }),
        );
      }
      if (snap.docs.length < _resultPageSize) {
        _hasMoreBusinesses = false;
      }
    } catch (_) {
      _hasMoreBusinesses = false;
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingBusinesses = false;
        });
      }
    }
  }

  Future<void> _loadMoreUsers() async {
    if (_isLoadingUsers || !_hasMoreUsers) return;
    setState(() {
      _isLoadingUsers = true;
    });
    try {
      Query<Map<String, dynamic>> query = FirebaseFirestore.instance
          .collection('users')
          .orderBy('name')
          .limit(_resultPageSize);
      if (_userLastDoc != null) {
        query = query.startAfterDocument(_userLastDoc!);
      }
      final snap = await query.get();
      if (snap.docs.isNotEmpty) {
        _userLastDoc = snap.docs.last;
        _userResults.addAll(
          snap.docs.map((d) {
            final data = d.data();
            return {...data, 'id': d.id};
          }),
        );
      }
      if (snap.docs.length < _resultPageSize) {
        _hasMoreUsers = false;
      }
    } catch (_) {
      _hasMoreUsers = false;
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingUsers = false;
        });
      }
    }
  }
  Future<void> _loadMorePosts() async {
    if (_isLoadingPosts || !_hasMorePosts) return;
    setState(() {
      _isLoadingPosts = true;
    });
    try {
      Query<Map<String, dynamic>> query = FirebaseFirestore.instance
          .collection('posts')
          .orderBy('createdAt', descending: true)
          .limit(_postPageSize);
      if (_postLastDoc != null) {
        query = query.startAfterDocument(_postLastDoc!);
      }
      final snap = await query.get();
      if (snap.docs.isNotEmpty) {
        _postLastDoc = snap.docs.last;
        final fetched = snap.docs.map(Post.fromFirestore).toList();
        _postResults.addAll(fetched);
      }
      if (snap.docs.length < _postPageSize) {
        _hasMorePosts = false;
      }
    } catch (_) {
      _hasMorePosts = false;
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingPosts = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final query = _controller.text.trim().toLowerCase();
    _ensurePostsLoaded(query);
    _ensureResultsLoaded(query);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Discover'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _controller,
              style: TextStyle(
                color: isDark ? Colors.white : Colors.black87,
              ),
              decoration: InputDecoration(
                hintText: 'Search pages, users, or posts',
                hintStyle: TextStyle(
                  color: isDark ? Colors.white54 : AppColors.grey,
                ),
                prefixIcon: Icon(
                  Icons.search,
                  color: isDark ? Colors.white70 : AppColors.grey,
                ),
                filled: true,
                fillColor: theme.cardColor,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          if (query.isEmpty) ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _DiscoverSpotlightCard(
                pageCount: _businessResults.length,
                userCount: _userResults.length,
                postCount: _postResults.length,
              ),
            ),
          ],
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                _quickExplorePill(
                  icon: Icons.trending_up_rounded,
                  label: 'Trending posts',
                  selected: _filter == SearchFilter.posts,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() {
                      _filter = _filter == SearchFilter.posts
                          ? SearchFilter.all
                          : SearchFilter.posts;
                    });
                  },
                ),
                _quickExplorePill(
                  icon: Icons.storefront_rounded,
                  label: 'Fresh pages',
                  selected: _filter == SearchFilter.businesses,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() {
                      _filter = _filter == SearchFilter.businesses
                          ? SearchFilter.all
                          : SearchFilter.businesses;
                    });
                  },
                ),
                _quickExplorePill(
                  icon: Icons.people_alt_rounded,
                  label: 'Meet users',
                  selected: _filter == SearchFilter.users,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() {
                      _filter = _filter == SearchFilter.users
                          ? SearchFilter.all
                          : SearchFilter.users;
                    });
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Builder(
              builder: (context) {
                final results = _buildResults(
                  query: query,
                  businesses: _businessResults,
                  users: _userResults,
                );

                final filteredPosts = query.isEmpty
                    ? _postResults
                    : _postResults.where((post) {
                        final name = post.businessName.toLowerCase();
                        final content = post.content.toLowerCase();
                        return name.contains(query) || content.contains(query);
                      }).toList();

                if (_filter == SearchFilter.posts) {
                  if (filteredPosts.isEmpty && !_isLoadingPosts) {
                    return const Center(child: Text('No results'));
                  }
                  return ListView.builder(
                    controller: _postScrollController,
                    itemCount:
                        filteredPosts.length + (_isLoadingPosts ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= filteredPosts.length) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                            child: CircularProgressIndicator(),
                          ),
                        );
                      }
                      final post = filteredPosts[index];
                      return _PostResultCard(
                        post: post,
                        onTap: () {
                          context.push('${AppRoutes.feed}?postId=${post.id}');
                        },
                      );
                    },
                  );
                }

                if (results.isEmpty &&
                    (_filter != SearchFilter.all || filteredPosts.isEmpty) &&
                    !_isLoadingBusinesses &&
                    !_isLoadingUsers &&
                    !_isLoadingPosts) {
                  return const Center(child: Text('No results'));
                }

                if (_filter == SearchFilter.all) {
                  final pageResults = results
                      .where((item) => item.type == _SearchItemType.page)
                      .toList();
                  final userResults = results
                      .where((item) => item.type == _SearchItemType.user)
                      .toList();
                  final hasMore = _hasMoreBusinesses || _hasMoreUsers || _hasMorePosts;
                  final pagePreview = pageResults.take(4).toList();
                  final userPreview = userResults.take(4).toList();
                  final postPreview = filteredPosts.take(4).toList();

                  return ListView(
                    controller: _resultsScrollController,
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
                    children: [
                      if (pageResults.isNotEmpty) ...[
                        _sectionHeader(
                          'Pages',
                          onSeeAll: pageResults.length > pagePreview.length
                              ? () => setState(() => _filter = SearchFilter.businesses)
                              : null,
                        ),
                        ...pagePreview.map(_buildSearchTile),
                        const SizedBox(height: 14),
                      ],
                      if (userResults.isNotEmpty) ...[
                        _sectionHeader(
                          'Users',
                          onSeeAll: userResults.length > userPreview.length
                              ? () => setState(() => _filter = SearchFilter.users)
                              : null,
                        ),
                        ...userPreview.map(_buildSearchTile),
                        const SizedBox(height: 14),
                      ],
                      if (filteredPosts.isNotEmpty) ...[
                        _sectionHeader(
                          'Posts',
                          onSeeAll: filteredPosts.length > postPreview.length
                              ? () => setState(() => _filter = SearchFilter.posts)
                              : null,
                        ),
                        ...postPreview.map(
                          (post) => _PostResultCard(
                            post: post,
                            onTap: () {
                              context.push('${AppRoutes.feed}?postId=${post.id}');
                            },
                          ),
                        ),
                      ],
                      if (hasMore)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                    ],
                  );
                }

                final hasMoreBusinesses =
                    _filter == SearchFilter.businesses ||
                        _filter == SearchFilter.all;
                final hasMoreUsers =
                    _filter == SearchFilter.users ||
                        _filter == SearchFilter.all;
                final hasMore = (hasMoreBusinesses && _hasMoreBusinesses) ||
                    (hasMoreUsers && _hasMoreUsers);

                return ListView.separated(
                  controller: _resultsScrollController,
                  itemCount: results.length + (hasMore ? 1 : 0),
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    if (index >= results.length) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    final item = results[index];
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: AppColors.primary,
                        backgroundImage:
                            item.imageUrl != null ? NetworkImage(item.imageUrl!) : null,
                        child: item.imageUrl == null
                            ? Text(
                                item.title.isNotEmpty
                                    ? item.title[0].toUpperCase()
                                    : '?',
                                style: const TextStyle(color: Colors.white),
                              )
                            : null,
                      ),
                      title: Text(item.title),
                      subtitle: Text(item.subtitle),
                      trailing: _buildTrailing(item),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        item.onTap();
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title, {VoidCallback? onSeeAll}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 10),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          if (onSeeAll != null)
            TextButton(
              onPressed: onSeeAll,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('See all'),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchTile(_SearchItem item) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: CircleAvatar(
        backgroundColor: AppColors.primary,
        backgroundImage:
            item.imageUrl != null ? NetworkImage(item.imageUrl!) : null,
        child: item.imageUrl == null
            ? Text(
                item.title.isNotEmpty ? item.title[0].toUpperCase() : '?',
                style: const TextStyle(color: Colors.white),
              )
            : null,
      ),
      title: Text(item.title),
      subtitle: Text(item.subtitle),
      trailing: _buildTrailing(item),
      onTap: () {
        HapticFeedback.selectionClick();
        item.onTap();
      },
    );
  }

  Widget _quickExplorePill({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: ActionChip(
        onPressed: onTap,
        avatar: Icon(
          icon,
          size: 18,
          color: selected ? Colors.white : AppColors.primary,
        ),
        label: Text(label),
        side: BorderSide(
          color: selected
              ? AppColors.primary
              : AppColors.primary.withValues(alpha: 0.18),
        ),
        backgroundColor: selected
            ? AppColors.primary
            : AppColors.primary.withValues(alpha: 0.08),
        labelStyle: TextStyle(
          fontWeight: FontWeight.w700,
          color: selected ? Colors.white : null,
        ),
      ),
    );
  }

  List<_SearchItem> _buildResults({
    required String query,
    required List<Map<String, dynamic>> businesses,
    required List<Map<String, dynamic>> users,
  }) {
    final List<_SearchItem> results = [];

    bool matches(String value) {
      if (query.isEmpty) return true;
      return value.toLowerCase().contains(query);
    }

    if (_filter == SearchFilter.all || _filter == SearchFilter.businesses) {
      final orderedBusinesses = List<Map<String, dynamic>>.from(businesses);
      if (!_businessOrderByName) {
        orderedBusinesses.sort((a, b) {
          final an = (a['name'] ?? '').toString().toLowerCase();
          final bn = (b['name'] ?? '').toString().toLowerCase();
          return an.compareTo(bn);
        });
      }
      for (final b in orderedBusinesses) {
        final name = (b['name'] ?? '').toString();
        final category = (b['category'] ?? '').toString();
        if (matches(name) || matches(category)) {
          results.add(
            _SearchItem(
              title: name.isEmpty ? 'Creator' : name,
              subtitle: category.isEmpty ? 'Creator' : category,
              imageUrl: b['imageUrl'] as String?,
              typeIcon: Icons.storefront,
              type: _SearchItemType.page,
              targetId: (b['id'] ?? b['businessId']).toString(),
              onTap: () {
                final id = b['id'] ?? b['businessId'];
                if (id != null && context.mounted) {
                  context.push(AppRoutes.businessProfilePath(id));
                }
              },
            ),
          );
        }
      }
    }

    if (_filter == SearchFilter.all || _filter == SearchFilter.users) {
      for (final u in users) {
        final name = (u['name'] ?? '').toString();
        final userType = (u['userType'] ?? '').toString();
        if (matches(name)) {
          final label = userType == 'business' ? 'Creator' : 'User';
          final id = u['id'] ?? '';
          results.add(
            _SearchItem(
              title: name.isEmpty ? 'User' : name,
              subtitle: label,
              imageUrl: u['imageUrl'] as String?,
              typeIcon: Icons.person,
              type: _SearchItemType.user,
              targetId: id.toString(),
              onTap: () {
                if (id.toString().isNotEmpty && context.mounted) {
                  context.push(AppRoutes.clientProfilePath(id.toString()));
                }
              },
            ),
          );
        }
      }
    }

    return results;
  }

  Widget _buildTrailing(_SearchItem item) {
    if (_currentUserId == null) {
      return Icon(item.typeIcon, color: AppColors.grey);
    }

    if (item.type == _SearchItemType.user &&
        item.targetId == _currentUserId) {
      return Icon(item.typeIcon, color: AppColors.grey);
    }

    if (item.type == _SearchItemType.page) {
      final docId = '${_currentUserId}_${item.targetId}';
      return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('page_follows')
            .doc(docId)
            .snapshots(),
        builder: (context, snap) {
          final isFollowing = snap.data?.exists == true;
          return TextButton(
            onPressed: () async {
              HapticFeedback.lightImpact();
              if (isFollowing) {
                await FirebaseFirestore.instance
                    .collection('page_follows')
                    .doc(docId)
                    .delete();
              } else {
                await FirebaseFirestore.instance
                    .collection('page_follows')
                    .doc(docId)
                    .set({
                  'followerId': _currentUserId,
                  'pageId': item.targetId,
                  'createdAt': FieldValue.serverTimestamp(),
                });
              }
            },
            child: Text(isFollowing ? 'Following' : 'Follow'),
          );
        },
      );
    }

    if (item.type == _SearchItemType.user) {
      final docId = '${_currentUserId}_${item.targetId}';
      return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('user_follows')
            .doc(docId)
            .snapshots(),
        builder: (context, snap) {
          final isFollowing = snap.data?.exists == true;
          return TextButton(
            onPressed: () async {
              HapticFeedback.lightImpact();
              if (isFollowing) {
                await FirebaseFirestore.instance
                    .collection('user_follows')
                    .doc(docId)
                    .delete();
              } else {
                await FirebaseFirestore.instance
                    .collection('user_follows')
                    .doc(docId)
                    .set({
                  'followerId': _currentUserId,
                  'followingId': item.targetId,
                  'createdAt': FieldValue.serverTimestamp(),
                });
                await SocialNotificationService.createFollowNotification(
                  followerId: _currentUserId!,
                  followingId: item.targetId,
                );
              }
            },
            child: Text(isFollowing ? 'Following' : 'Follow'),
          );
        },
      );
    }

    return Icon(item.typeIcon, color: AppColors.grey);
  }
}

class _DiscoverSpotlightCard extends StatelessWidget {
  const _DiscoverSpotlightCard({
    required this.pageCount,
    required this.userCount,
    required this.postCount,
  });

  final int pageCount;
  final int userCount;
  final int postCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.primary.withValues(alpha: 0.18),
            Colors.orange.withValues(alpha: 0.14),
          ],
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(
              Icons.auto_awesome_rounded,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Discover what is moving right now',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$pageCount pages  •  $userCount users  •  $postCount posts loaded',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.82),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PostResultCard extends StatelessWidget {
  const _PostResultCard({
    required this.post,
    required this.onTap,
  });

  final Post post;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final thumb = _postThumbnail(post);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Card(
        elevation: 1,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (thumb != null)
                ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(12)),
                  child: Image.network(
                    thumb,
                    height: 180,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                )
              else
                Container(
                  height: 180,
                  width: double.infinity,
                  decoration: const BoxDecoration(
                    color: AppColors.lightGrey,
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(12)),
                  ),
                  child: const Icon(Icons.photo, size: 40),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      post.businessName.isNotEmpty
                          ? post.businessName
                          : 'Creator',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      post.content.isNotEmpty ? post.content : 'Post',
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
      ),
    );
  }

  String? _postThumbnail(Post post) {
    if (post.media.isNotEmpty) {
      final image = post.media.firstWhere(
        (m) => !m.isVideo,
        orElse: () => const PostMedia(type: PostMediaType.video, url: ''),
      );
      if (image.url.isNotEmpty) return image.url;
    }
    return post.imageUrl;
  }
}

class _SearchItem {
  final String title;
  final String subtitle;
  final String? imageUrl;
  final IconData typeIcon;
  final VoidCallback onTap;
  final _SearchItemType type;
  final String targetId;

  _SearchItem({
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    required this.typeIcon,
    required this.onTap,
    required this.type,
    required this.targetId,
  });
}

enum _SearchItemType { user, page }
