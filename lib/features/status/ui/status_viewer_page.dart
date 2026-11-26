import 'dart:async';
import 'dart:io' show Platform;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart' as mkv;
import 'package:video_player/video_player.dart';

import '../../../core/i18n/tr.dart';
import '../../moderation/moderation.dart';
import '../data/status_repository.dart';

/// Full-screen status viewer. Tap right = next, tap left = back,
/// hold = pause, swipe down = close. Goes on to the next person at the end.
/// Desktop: arrow keys, Space (pause) and Esc; videos play with media_kit.
class StatusViewerPage extends StatefulWidget {
  const StatusViewerPage(
      {super.key, required this.groups, required this.startGroup});
  final List<StatusGroup> groups;
  final int startGroup;

  @override
  State<StatusViewerPage> createState() => _StatusViewerPageState();
}

class _StatusViewerPageState extends State<StatusViewerPage>
    with SingleTickerProviderStateMixin {
  static const _photoTime = Duration(seconds: 6);
  final _repo = StatusRepository.instance;
  late int _group = widget.startGroup;
  int _index = 0;
  late final AnimationController _progress = AnimationController(vsync: this)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) _next();
    });
  VideoPlayerController? _video;
  // Windows: video_player has no Windows version, media_kit does.
  mk.Player? _deskPlayer;
  mkv.VideoController? _deskVideo;
  StreamSubscription<Duration>? _deskDuration;
  bool _paused = false;
  final FocusNode _focus = FocusNode();

  StatusGroup get _g => widget.groups[_group];
  StatusItem get _s => _g.items[_index];
  bool get _isMine => _g.ownerId == FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    _show();
  }

  @override
  void dispose() {
    _progress.dispose();
    _video?.dispose();
    _disposeDesktopVideo();
    _focus.dispose();
    super.dispose();
  }

  void _disposeDesktopVideo() {
    _deskDuration?.cancel();
    _deskDuration = null;
    _deskPlayer?.dispose();
    _deskPlayer = null;
    _deskVideo = null;
  }

  Future<void> _showDesktopVideo(String url) async {
    final player = mk.Player();
    _deskPlayer = player;
    _deskVideo = mkv.VideoController(player);
    setState(() {});
    // Start the progress bar once we know how long the video is.
    _deskDuration = player.stream.duration.listen((d) {
      if (d > Duration.zero && _progress.duration == null && mounted) {
        _progress.duration = d;
        if (!_paused) _progress.forward();
      }
    });
    try {
      await player.open(mk.Media(url));
    } catch (_) {
      _progress.duration = _photoTime;
      _progress.forward();
    }
  }

  Future<void> _show() async {
    _progress.stop();
    _progress.value = 0;
    await _video?.dispose();
    _video = null;
    _disposeDesktopVideo();
    _progress.duration = null;
    final s = _s;
    unawaited(_repo.markSeen(s));
    if (s.type == 'video' && s.mediaUrl != null && Platform.isWindows) {
      await _showDesktopVideo(s.mediaUrl!);
    } else if (s.type == 'video' && s.mediaUrl != null) {
      final c = VideoPlayerController.networkUrl(Uri.parse(s.mediaUrl!));
      _video = c;
      setState(() {});
      try {
        await c.initialize();
        if (!mounted || _video != c) return;
        _progress.duration =
            c.value.duration.inMilliseconds > 0 ? c.value.duration : _photoTime;
        await c.play();
        _progress.forward();
        setState(() {});
      } catch (_) {
        _progress.duration = _photoTime;
        _progress.forward();
      }
    } else {
      _progress.duration = _photoTime;
      _progress.forward();
      setState(() {});
    }
  }

  void _next() {
    if (_index < _g.items.length - 1) {
      setState(() => _index++);
      _show();
    } else if (_group < widget.groups.length - 1) {
      setState(() {
        _group++;
        _index = 0;
      });
      _show();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _back() {
    if (_index > 0) {
      setState(() => _index--);
    } else if (_group > 0) {
      setState(() {
        _group--;
        _index = 0;
      });
    }
    _show();
  }

  void _pause(bool paused) {
    _paused = paused;
    if (paused) {
      _progress.stop();
      _video?.pause();
      _deskPlayer?.pause();
    } else {
      if (_progress.duration != null) _progress.forward();
      _video?.play();
      _deskPlayer?.play();
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight) {
      _next();
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _back();
    } else if (key == LogicalKeyboardKey.space) {
      _pause(!_paused);
    } else if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Future<void> _showViewers() async {
    _pause(true);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => StreamBuilder<List<Map<String, dynamic>>>(
        stream: _repo.viewers(_s.id),
        builder: (context, snap) {
          final list = snap.data ?? [];
          if (list.isEmpty) {
            return SizedBox(
                height: 160, child: Center(child: Text(tr('No views yet'))));
          }
          return ListView(
            shrinkWrap: true,
            children: [
              for (final v in list)
                ListTile(
                  leading: CircleAvatar(
                    backgroundImage:
                        (v['viewerImageUrl'] as String?)?.startsWith('http') ==
                                true
                            ? CachedNetworkImageProvider(
                                v['viewerImageUrl'] as String)
                            : null,
                  ),
                  title: Text((v['viewerName'] ?? 'User').toString()),
                ),
            ],
          );
        },
      ),
    );
    if (mounted) _pause(false);
  }

  Future<void> _delete() async {
    _pause(true);
    final nav = Navigator.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Delete this status?')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr('Cancel'))),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr('Delete'))),
        ],
      ),
    );
    if (ok == true) {
      await _repo.delete(_s.id);
      nav.pop();
    } else {
      _pause(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final ago = DateTime.now().difference(s.createdAt);
    final when =
        ago.inMinutes < 60 ? '${ago.inMinutes} min' : '${ago.inHours} h';

    Widget body;
    if (s.type == 'image' && s.mediaUrl != null) {
      body = CachedNetworkImage(imageUrl: s.mediaUrl!, fit: BoxFit.contain);
    } else if (s.type == 'video') {
      final c = _video;
      final desk = _deskVideo;
      body = Platform.isWindows
          ? (desk != null
              ? mkv.Video(
                  controller: desk,
                  controls: mkv.NoVideoControls,
                  fit: BoxFit.contain)
              : const Center(
                  child: CircularProgressIndicator(color: Colors.white)))
          : c != null && c.value.isInitialized
              ? Center(
                  child: AspectRatio(
                      aspectRatio: c.value.aspectRatio, child: VideoPlayer(c)))
              : const Center(
                  child: CircularProgressIndicator(color: Colors.white));
    } else {
      body = Container(
        color: Color(s.bgColor),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(32),
        child: Text(
          s.text,
          textAlign: TextAlign.center,
          style: const TextStyle(
              color: Colors.white, fontSize: 28, fontWeight: FontWeight.w700),
        ),
      );
    }

    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          onTapUp: (d) {
            final w = MediaQuery.of(context).size.width;
            d.globalPosition.dx < w / 3 ? _back() : _next();
          },
          onLongPressStart: (_) => _pause(true),
          onLongPressEnd: (_) => _pause(false),
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) > 300) {
              Navigator.of(context).maybePop();
            }
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              body,
              if (s.type != 'text' && s.text.isNotEmpty)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 90,
                  child: Text(
                    s.text,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      shadows: [Shadow(blurRadius: 6, color: Colors.black)],
                    ),
                  ),
                ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                  child: Column(
                    children: [
                      AnimatedBuilder(
                        animation: _progress,
                        builder: (_, __) => Row(
                          children: [
                            for (var i = 0; i < _g.items.length; i++)
                              Expanded(
                                child: Padding(
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 2),
                                  child: LinearProgressIndicator(
                                    value: i < _index
                                        ? 1
                                        : (i == _index ? _progress.value : 0),
                                    minHeight: 2.5,
                                    backgroundColor: Colors.white24,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 18,
                            backgroundImage:
                                _g.imageUrl?.startsWith('http') == true
                                    ? CachedNetworkImageProvider(_g.imageUrl!)
                                    : null,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '${_isMine ? tr('Your status') : _g.name} · $when',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (!_isMine)
                            IconButton(
                              onPressed: () async {
                                _pause(true);
                                await showUserSafetySheet(context,
                                    userId: _g.ownerId,
                                    name: _g.name,
                                    reportType: 'status',
                                    reportId: s.id,
                                    preview: s.text);
                                if (mounted) _pause(false);
                              },
                              icon: const Icon(Icons.more_vert_rounded,
                                  color: Colors.white),
                            ),
                          if (_isMine)
                            IconButton(
                              onPressed: _delete,
                              icon: const Icon(Icons.delete_outline_rounded,
                                  color: Colors.white),
                            ),
                          IconButton(
                            onPressed: () => Navigator.of(context).maybePop(),
                            icon: const Icon(Icons.close_rounded,
                                color: Colors.white),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (_isMine)
                Positioned(
                  bottom: 24,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: TextButton.icon(
                      onPressed: _showViewers,
                      icon: const Icon(Icons.visibility_rounded,
                          color: Colors.white),
                      label: Text('${s.viewCount}',
                          style: const TextStyle(color: Colors.white)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
