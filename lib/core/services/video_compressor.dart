import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:video_compress/video_compress.dart';

/// Shrinks videos on the phone before upload (Phase 3).
///
/// A phone camera video is often 30-80 MB for one minute. Re-encoded at
/// 720p it is usually 5-10x smaller, which means:
///  - uploads finish on 3G,
///  - viewers' data bundles last longer,
///  - reels start playing faster.
///
/// Works on Android and iOS. On Windows/desktop the file is used as it is.
class VideoCompressor {
  VideoCompressor._();

  /// Files smaller than this are already light enough.
  static const int _skipBelowBytes = 3 * 1024 * 1024;

  static bool get isSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Returns a smaller copy of [input], or [input] itself if compression is
  /// not needed, not supported, or fails.
  static Future<File> compress(
    File input, {
    void Function(double percent)? onProgress,
  }) async {
    if (!isSupported) return input;
    final size = await input.length();
    if (size < _skipBelowBytes) return input;

    Subscription? progressSub;
    if (onProgress != null) {
      progressSub = VideoCompress.compressProgress$.subscribe(onProgress);
    }
    try {
      final info = await VideoCompress.compressVideo(
        input.path,
        quality: VideoQuality.Res1280x720Quality,
        includeAudio: true,
        frameRate: 30,
      );
      final out = info?.file;
      if (out == null || !await out.exists()) return input;
      // Keep the original if the "compressed" one somehow got bigger.
      return await out.length() < size ? out : input;
    } catch (e) {
      debugPrint('Video compression failed, uploading original: $e');
      return input;
    } finally {
      progressSub?.unsubscribe();
    }
  }

  /// Removes temporary compressed files after upload.
  static Future<void> cleanUp() async {
    if (!isSupported) return;
    try {
      await VideoCompress.deleteAllCache();
    } catch (_) {}
  }
}
