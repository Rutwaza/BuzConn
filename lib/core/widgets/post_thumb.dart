import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../data/models/post_model.dart';
import '../services/video_frame_grabber.dart';

/// Small square preview of a post for grids (profile, page, saved...).
/// Photos: the photo. Videos: their cover, or a frame taken from the video.
/// Text posts: the first words on a coloured tile.
class PostThumb extends StatelessWidget {
  const PostThumb({super.key, required this.post, this.showVideoIcon = true});

  final Post post;
  final bool showVideoIcon;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(builder: (context, c) {
      final px = ((c.maxWidth.isFinite ? c.maxWidth : 240) * dpr).round();
      if (post.media.isEmpty) return _TextTile(text: post.content);
      final first = post.media.first;
      if (!first.isVideo) {
        return CachedNetworkImage(
          imageUrl: first.url,
          fit: BoxFit.cover,
          memCacheWidth: px,
          fadeInDuration: const Duration(milliseconds: 220),
          placeholder: (_, __) => const _Loading(),
          errorWidget: (_, __, ___) => const _VideoBox(),
        );
      }
      return Stack(
        fit: StackFit.expand,
        children: [
          VideoCover(media: first, width: px),
          if (showVideoIcon)
            const Positioned(
              right: 6,
              top: 6,
              child: Icon(Icons.play_circle_fill_rounded,
                  color: Colors.white,
                  size: 22,
                  shadows: [Shadow(blurRadius: 6, color: Colors.black54)]),
            ),
        ],
      );
    });
  }
}

/// The cover picture of a video: thumbnailUrl if the post has one, else a
/// frame grabbed from the video, else a dark tile.
class VideoCover extends StatelessWidget {
  const VideoCover(
      {super.key,
      required this.media,
      this.width = 480,
      this.fit = BoxFit.cover});

  final PostMedia media;
  final int width;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final thumb = media.thumbnailUrl;
    if (thumb != null && thumb.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: thumb,
        fit: fit,
        memCacheWidth: width,
        fadeInDuration: const Duration(milliseconds: 220),
        placeholder: (_, __) => const _VideoBox(),
        errorWidget: (_, __, ___) => _Grabbed(url: media.url, fit: fit),
      );
    }
    return _Grabbed(url: media.url, fit: fit);
  }
}

class _Grabbed extends StatefulWidget {
  const _Grabbed({required this.url, required this.fit});
  final String url;
  final BoxFit fit;

  @override
  State<_Grabbed> createState() => _GrabbedState();
}

class _GrabbedState extends State<_Grabbed> {
  late final Future<dynamic> _future = VideoFrameGrabber.frame(widget.url);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<dynamic>(
      future: _future,
      builder: (context, snap) {
        final bytes = snap.data;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: bytes == null
              ? const _VideoBox(key: ValueKey('box'))
              : Image.memory(bytes,
                  key: const ValueKey('img'),
                  fit: widget.fit,
                  gaplessPlayback: true),
        );
      },
    );
  }
}

class _VideoBox extends StatelessWidget {
  const _VideoBox({super.key});

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1B2433), Color(0xFF0B0F16)],
        ),
      ),
      child: Center(
        child: Icon(Icons.movie_rounded, color: Colors.white24, size: 30),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
    );
  }
}

class _TextTile extends StatelessWidget {
  const _TextTile({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primary.withValues(alpha: 0.85), scheme.tertiary],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        text.trim().isEmpty ? '…' : text.trim(),
        maxLines: 5,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: const TextStyle(
            color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
      ),
    );
  }
}
