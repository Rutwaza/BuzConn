import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:businessfinder/core/i18n/tr.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:businessfinder/core/widgets/post_thumb.dart';
import '../../../core/theme/colors.dart';
import '../../../data/models/post_model.dart';
import '../business/post_detail_page.dart';

/// Saved posts as a 3-across grid (like a profile), newest first.
/// Tap: open the post. Long-press or right-click: remove from Saved.
class FavoritesPage extends StatelessWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return Scaffold(body: Center(child: Text(tr('Please sign in.'))));
    }

    return Scaffold(
      appBar: AppBar(title: Text(tr('Saved'))),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('favorites')
            .orderBy('createdAt', descending: true)
            .snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting &&
              !snap.hasData) {
            return _grid(context, count: 9, builder: (_) => const _TileShimmer());
          }
          final docs = snap.data?.docs ?? [];
          if (docs.isEmpty) return const _EmptySaved();
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                child: Row(children: [
                  const Icon(Icons.bookmark_rounded,
                      size: 18, color: AppColors.primary),
                  const SizedBox(width: 6),
                  Text(
                    docs.length == 1
                        ? tr('1 saved post')
                        : '${docs.length} ${tr('saved posts')}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  Text(tr('Only you can see this'),
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.grey)),
                ]),
              ),
              Expanded(
                child: _grid(
                  context,
                  count: docs.length,
                  builder: (i) => _SavedTile(
                    key: ValueKey(docs[i].id),
                    postId: docs[i].id,
                    userId: user.uid,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 3 across on phones; on wide screens the grid stays a comfortable
  /// width in the middle (like Instagram on the web).
  Widget _grid(BuildContext context,
      {required int count, required Widget Function(int) builder}) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 935),
        child: GridView.builder(
          padding: const EdgeInsets.fromLTRB(2, 0, 2, 24),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 3,
            crossAxisSpacing: 3,
          ),
          itemCount: count,
          itemBuilder: (_, i) => builder(i),
        ),
      ),
    );
  }
}

class _SavedTile extends StatefulWidget {
  const _SavedTile({super.key, required this.postId, required this.userId});

  final String postId;
  final String userId;

  @override
  State<_SavedTile> createState() => _SavedTileState();
}

class _SavedTileState extends State<_SavedTile> {
  // One read per tile (not a live listener): lighter with many saves.
  late final Future<DocumentSnapshot<Map<String, dynamic>>> _post =
      FirebaseFirestore.instance.collection('posts').doc(widget.postId).get();
  bool _hover = false;

  Future<void> _unsave() async {
    await FirebaseFirestore.instance
        .collection('users')
        .doc(widget.userId)
        .collection('favorites')
        .doc(widget.postId)
        .delete();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(tr('Removed from Saved'))));
  }

  Future<void> _menu(Offset? at) async {
    final choice = at == null
        ? await showModalBottomSheet<String>(
            context: context,
            showDragHandle: true,
            builder: (c) => SafeArea(
              child: ListTile(
                leading: const Icon(Icons.bookmark_remove_rounded),
                title: Text(tr('Remove from Saved')),
                onTap: () => Navigator.pop(c, 'remove'),
              ),
            ),
          )
        : await showMenu<String>(
            context: context,
            position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
            items: [
              PopupMenuItem(
                value: 'remove',
                child: Row(children: [
                  const Icon(Icons.bookmark_remove_rounded, size: 18),
                  const SizedBox(width: 10),
                  Text(tr('Remove from Saved')),
                ]),
              ),
            ],
          );
    if (choice == 'remove') await _unsave();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: _post,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const _TileShimmer();
        }
        final doc = snap.data;
        if (doc == null || !doc.exists) {
          return _GoneTile(onRemove: _unsave);
        }
        final post = Post.fromFirestore(doc);
        return MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => PostDetailPage(post: post),
            )),
            onLongPress: () => _menu(null),
            onSecondaryTapDown: (d) => _menu(d.globalPosition),
            child: Stack(fit: StackFit.expand, children: [
              PostThumb(post: post, showVideoIcon: false),
              // Type badge, top right (video / several photos).
              if (post.media.isNotEmpty)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Icon(
                    post.media.first.isVideo
                        ? Icons.play_arrow_rounded
                        : post.media.length > 1
                            ? Icons.collections_rounded
                            : null,
                    color: Colors.white,
                    size: 20,
                    shadows: const [
                      Shadow(blurRadius: 6, color: Colors.black54)
                    ],
                  ),
                ),
              // Always visible: what it is and who posted it, so you can tell
              // saved posts apart even when a video has no picture yet.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(8, 22, 8, 7),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.78),
                        ],
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (post.businessName.trim().isNotEmpty)
                          Text(
                            post.businessName.trim(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        if (post.content.trim().isNotEmpty)
                          Text(
                            post.content.trim().replaceAll('\n', ' '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 10.5,
                              height: 1.2,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              // Kind of post, top left.
              Positioned(
                left: 6,
                top: 6,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    post.media.isEmpty
                        ? tr('Text')
                        : post.media.first.isVideo
                            ? tr('Video')
                            : post.media.length > 1
                                ? tr('Photos')
                                : tr('Photo'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              // Hover (desktop): likes and comments, like Instagram.
              AnimatedOpacity(
                opacity: _hover ? 1 : 0,
                duration: const Duration(milliseconds: 140),
                child: Container(
                  color: Colors.black.withValues(alpha: 0.38),
                  alignment: Alignment.center,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.favorite_rounded,
                        color: Colors.white, size: 18),
                    const SizedBox(width: 4),
                    Text('${post.likeCount}',
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w800)),
                    const SizedBox(width: 14),
                    const Icon(Icons.mode_comment_rounded,
                        color: Colors.white, size: 17),
                    const SizedBox(width: 4),
                    Text('${post.commentCount}',
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w800)),
                  ]),
                ),
              ),
            ]),
          ),
        );
      },
    );
  }
}

class _GoneTile extends StatelessWidget {
  const _GoneTile({required this.onRemove});
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: InkWell(
        onTap: onRemove,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.hide_image_outlined, color: AppColors.grey),
          const SizedBox(height: 6),
          Text(tr('Post deleted'),
              style: const TextStyle(fontSize: 12, color: AppColors.grey)),
          const SizedBox(height: 2),
          Text(tr('Tap to remove'),
              style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.primary,
                  fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }
}

class _TileShimmer extends StatelessWidget {
  const _TileShimmer();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest);
  }
}

class _EmptySaved extends StatelessWidget {
  const _EmptySaved();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                  color: Theme.of(context).colorScheme.onSurface, width: 2),
            ),
            child: const Icon(Icons.bookmark_border_rounded, size: 40),
          ),
          const SizedBox(height: 16),
          Text(tr('Save posts you love'),
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            tr('Tap the bookmark on any post to keep it here. Only you can see what you save.'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.grey),
          ),
        ]),
      ),
    );
  }
}
