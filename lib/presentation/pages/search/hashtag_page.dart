import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/i18n/tr.dart';
import '../../../core/theme/colors.dart';
import '../../../core/widgets/post_thumb.dart';
import '../../../data/models/post_model.dart';
import '../business/post_detail_page.dart';

/// All posts with one #hashtag, newest first, as a grid.
/// Posts get `hashtags` from the server (functions/tags.js + feed.js).
class HashtagPage extends StatefulWidget {
  const HashtagPage({super.key, required this.tag});
  final String tag;

  @override
  State<HashtagPage> createState() => _HashtagPageState();
}

class _HashtagPageState extends State<HashtagPage> {
  static const _pageSize = 30;
  final _posts = <Post>[];
  DocumentSnapshot? _last;
  bool _loading = false;
  bool _done = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _more();
  }

  Future<void> _more() async {
    if (_loading || _done) return;
    setState(() => _loading = true);
    try {
      Query<Map<String, dynamic>> q = FirebaseFirestore.instance
          .collection('posts')
          .where('hashtags', arrayContains: widget.tag)
          .orderBy('createdAt', descending: true)
          .limit(_pageSize);
      if (_last != null) q = q.startAfterDocument(_last!);
      final snap = await q.get();
      _posts.addAll(snap.docs.map(Post.fromFirestore));
      if (snap.docs.isNotEmpty) _last = snap.docs.last;
      _done = snap.docs.length < _pageSize;
    } catch (e) {
      _error = e;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: Text('#${widget.tag}')),
      body: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.pixels > n.metrics.maxScrollExtent - 400) _more();
          return false;
        },
        child: CustomScrollView(slivers: [
          SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 935),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                  child: Row(children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(colors: [
                          AppColors.primary,
                          AppColors.secondary.withValues(alpha: isDark ? 0.8 : 1),
                        ]),
                      ),
                      alignment: Alignment.center,
                      child: const Text('#',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 34,
                              fontWeight: FontWeight.w900)),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('#${widget.tag}',
                                style: const TextStyle(
                                    fontSize: 22, fontWeight: FontWeight.w900)),
                            const SizedBox(height: 2),
                            Text(
                              _done
                                  ? '${_posts.length} ${_posts.length == 1 ? tr('post') : tr('posts')}'
                                  : '${_posts.length}+ ${tr('posts')}',
                              style: const TextStyle(color: AppColors.grey),
                            ),
                          ]),
                    ),
                  ]),
                ),
              ),
            ),
          ),
          if (_error != null && _posts.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text(tr('Could not load posts. Try again later.'))),
            )
          else if (_posts.isEmpty && _done)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    '${tr('No posts with')} #${widget.tag} ${tr('yet. Be the first!')}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.grey),
                  ),
                ),
              ),
            )
          else
            SliverToBoxAdapter(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 935),
                  child: GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(2, 0, 2, 24),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 3,
                      crossAxisSpacing: 3,
                    ),
                    itemCount: _posts.length + (_loading ? 3 : 0),
                    itemBuilder: (_, i) {
                      if (i >= _posts.length) {
                        return ColoredBox(
                            color: Theme.of(context).colorScheme.surfaceContainerHighest);
                      }
                      final post = _posts[i];
                      return GestureDetector(
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => PostDetailPage(post: post),
                        )),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: PostThumb(post: post),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
