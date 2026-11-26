import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../../core/i18n/tr.dart';
import '../../../core/theme/colors.dart';
import '../data/status_repository.dart';
import 'status_composer_page.dart';
import 'status_viewer_page.dart';

/// The row of round status bubbles at the top of the feed.
/// Teal ring = something new to watch, grey ring = already watched.
class StatusBar extends StatefulWidget {
  const StatusBar({super.key});

  @override
  State<StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<StatusBar> {
  final _repo = StatusRepository.instance;
  List<StatusGroup> _groups = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final g = await _repo.loadGroups();
      if (mounted) {
        setState(() {
  _groups = g;
  _loaded = true;
});
      }
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _compose() async {
    final posted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const StatusComposerPage()),
    );
    if (posted == true) await _load();
  }

  Future<void> _open(int index) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StatusViewerPage(groups: _groups, startGroup: index),
    ));
    if (mounted) setState(() {}); // refresh rings
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || !_loaded) return const SizedBox(height: 4);
    final mine = _groups.indexWhere((g) => g.ownerId == uid);
    final others = [
      for (var i = 0; i < _groups.length; i++)
        if (_groups[i].ownerId != uid) i,
    ];
    final me = FirebaseAuth.instance.currentUser!;

    return SizedBox(
      height: 104,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        children: [
          _Bubble(
            label: tr('Your status'),
            imageUrl: mine >= 0 ? _groups[mine].imageUrl : me.photoURL,
            name: me.displayName ?? '?',
            ring: mine >= 0
                ? (_repo.allSeen(_groups[mine]) ? AppColors.lightGrey : AppColors.secondary)
                : null,
            showAdd: true,
            onTap: mine >= 0 ? () => _open(mine) : _compose,
            onAdd: _compose,
          ),
          for (final i in others)
            _Bubble(
              label: _groups[i].name,
              imageUrl: _groups[i].imageUrl,
              name: _groups[i].name,
              ring: _repo.allSeen(_groups[i]) ? AppColors.lightGrey : AppColors.secondary,
              onTap: () => _open(i),
            ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.label,
    required this.name,
    required this.onTap,
    this.imageUrl,
    this.ring,
    this.showAdd = false,
    this.onAdd,
  });

  final String label;
  final String name;
  final String? imageUrl;
  final Color? ring;
  final bool showAdd;
  final VoidCallback onTap;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    final hasImage = url != null && url.startsWith('http');
    return Padding(
      padding: const EdgeInsets.only(right: 14),
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: 68,
          child: Column(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    padding: const EdgeInsets.all(2.5),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: ring ?? Colors.transparent,
                        width: 2.5,
                      ),
                    ),
                    child: CircleAvatar(
                      radius: 27,
                      backgroundColor: AppColors.mist,
                      backgroundImage: hasImage ? CachedNetworkImageProvider(url) : null,
                      child: hasImage
                          ? null
                          : Text(
                              name.isEmpty ? '?' : name[0].toUpperCase(),
                              style: const TextStyle(
                                  color: AppColors.primary, fontWeight: FontWeight.w800),
                            ),
                    ),
                  ),
                  if (showAdd)
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: GestureDetector(
                        onTap: onAdd,
                        child: Container(
                          decoration: BoxDecoration(
                            color: AppColors.primary,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                          child: const Icon(Icons.add, size: 18, color: Colors.white),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
