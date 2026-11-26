import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'image_shrinker.dart';

/// One place to pick photos and videos, used by every screen.
///
/// Why: on Windows, image_picker opens the file window ON the app's main
/// thread, so while Explorer loads a big folder (thumbnails, OneDrive...)
/// the whole app shows "Not responding". file_picker opens the same window
/// from a background worker, so the app stays alive. Big photos are also
/// shrunk in the background before the screen gets them.
///
/// On phones nothing changes: the normal image_picker is used.
class MediaPicker {
  MediaPicker._();

  static bool get _desktop => !kIsWeb && Platform.isWindows;

  static Future<XFile?> pickImage({
    ImageSource source = ImageSource.gallery,
    double? maxWidth,
    int? imageQuality,
  }) async {
    if (!_desktop) {
      return ImagePicker().pickImage(
        source: source,
        maxWidth: maxWidth ?? 1600,
        imageQuality: imageQuality ?? 85,
      );
    }
    if (source == ImageSource.camera) return null; // no camera on Windows
    final r = await FilePicker.platform.pickFiles(type: FileType.image);
    final path = r?.files.single.path;
    if (path == null) return null;
    return _shrunk(path, (maxWidth ?? 1600).round());
  }

  static Future<List<XFile>> pickMultiImage({double? maxWidth}) async {
    if (!_desktop) {
      return ImagePicker().pickMultiImage(
        maxWidth: maxWidth ?? 1600,
        imageQuality: 85,
      );
    }
    final r = await FilePicker.platform
        .pickFiles(type: FileType.image, allowMultiple: true);
    if (r == null) return const [];
    final out = <XFile>[];
    for (final f in r.files) {
      if (f.path != null)
        out.add(await _shrunk(f.path!, (maxWidth ?? 1600).round()));
    }
    return out;
  }

  static Future<XFile?> pickVideo({
    ImageSource source = ImageSource.gallery,
    Duration? maxDuration,
  }) async {
    if (!_desktop) {
      return ImagePicker().pickVideo(source: source, maxDuration: maxDuration);
    }
    if (source == ImageSource.camera) return null;
    final r = await FilePicker.platform.pickFiles(type: FileType.video);
    final path = r?.files.single.path;
    return path == null ? null : XFile(path);
  }

  /// Returns a smaller JPEG copy in the temp folder (or the original if it
  /// is already small or can't be read).
  static Future<XFile> _shrunk(String path, int maxSide) async {
    try {
      final original = File(path);
      final bytes = await original.readAsBytes();
      final small = await ImageShrinker.shrink(bytes, maxSide: maxSide);
      if (identical(small, bytes)) return XFile(path);
      final dir = await getTemporaryDirectory();
      final out = File(
          '${dir.path}${Platform.pathSeparator}duhuze_${DateTime.now().microsecondsSinceEpoch}.jpg');
      await out.writeAsBytes(small, flush: true);
      return XFile(out.path, mimeType: 'image/jpeg');
    } catch (e) {
      debugPrint('MediaPicker shrink skipped: $e');
      return XFile(path);
    }
  }
}
