import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

/// Gets a still picture (a "thumbnail") out of a video.
///
/// - Phones: the video_thumbnail plugin.
/// - Windows: that plugin doesn't exist there, so we open the video in a
///   tiny, muted, hidden media_kit player and take a screenshot.
///
/// Results are cached in memory and on disk, and only ONE video is opened
/// at a time, so a grid of 30 videos never opens 30 players together.
class VideoFrameGrabber {
  VideoFrameGrabber._();

  static final Map<String, Future<Uint8List?>> _memory = {};
  static Future<void> _queue = Future.value();

  /// A frame near [at] from a local file or an https URL. null if it fails.
  static Future<Uint8List?> frame(String source,
      {Duration at = const Duration(milliseconds: 900), int width = 480}) {
    final key = '$source@${at.inMilliseconds}@$width';
    return _memory.putIfAbsent(key, () => _load(source, at, width, key));
  }

  /// Several frames from a local file (to choose a video cover).
  static Future<List<Uint8List>> frames(String path, List<Duration> times,
      {int width = 480}) async {
    final out = <Uint8List>[];
    for (final t in times) {
      final f = await frame(path, at: t, width: width);
      if (f != null && f.isNotEmpty) out.add(f);
    }
    return out;
  }

  static Future<Uint8List?> _load(
      String source, Duration at, int width, String key) async {
    final cacheFile = await _cacheFile(key);
    if (cacheFile != null && await cacheFile.exists()) {
      return cacheFile.readAsBytes();
    }
    Uint8List? bytes;
    if (!Platform.isWindows) {
      bytes = await VideoThumbnail.thumbnailData(
        video: source,
        imageFormat: ImageFormat.JPEG,
        maxWidth: width,
        quality: 75,
        timeMs: at.inMilliseconds,
      ).catchError((_) => null);
    } else {
      // One at a time: wait for the previous grab to finish.
      final previous = _queue;
      final done = Completer<void>();
      _queue = done.future;
      await previous;
      try {
        bytes = await _grabWindows(source, at, width)
            .timeout(const Duration(seconds: 12), onTimeout: () => null);
      } finally {
        done.complete();
      }
    }
    if (bytes == null || bytes.isEmpty) {
      _memory.remove(key); // try again next time
      return null;
    }
    try {
      await cacheFile?.writeAsBytes(bytes, flush: true);
    } catch (_) {}
    return bytes;
  }

  static Future<Uint8List?> _grabWindows(
      String source, Duration at, int width) async {
    final player = Player(
      configuration: const PlayerConfiguration(
        muted: true,
        bufferSize: 4 * 1024 * 1024,
      ),
    );
    try {
      final controller = VideoController(
        player,
        configuration: VideoControllerConfiguration(
          width: width,
          height: (width * 16 / 9).round(),
        ),
      );
      await player.open(Media(source), play: false);
      await controller.waitUntilFirstFrameRendered
          .timeout(const Duration(seconds: 8));
      if (at > Duration.zero) {
        final length = player.state.duration;
        final target =
            length > Duration.zero && at > length ~/ 2 ? length ~/ 3 : at;
        await player.seek(target);
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
      return await player.screenshot(format: 'image/jpeg');
    } catch (e) {
      debugPrint('Video frame failed for $source: $e');
      return null;
    } finally {
      await player.dispose();
    }
  }

  static Directory? _dir;
  static Future<File?> _cacheFile(String key) async {
    try {
      _dir ??= Directory(
          '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}duhuze_thumbs');
      if (!await _dir!.exists()) await _dir!.create(recursive: true);
      final name = sha1.convert(utf8.encode(key)).toString();
      return File('${_dir!.path}${Platform.pathSeparator}$name.jpg');
    } catch (_) {
      return null;
    }
  }
}
