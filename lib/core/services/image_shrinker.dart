import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Makes photos smaller before upload.
///
/// On phones, image_picker already does this. On Windows it does not, so a
/// camera photo can be 5-15 MB. We resize it to at most [maxSide] pixels
/// and save it as JPEG, in a background worker (an isolate) so the window
/// never freezes while it works.
class ImageShrinker {
  ImageShrinker._();

  /// Photos smaller than this are already light: sent as they are.
  static const int _skipBelowBytes = 450 * 1024;

  static Future<Uint8List> shrink(
    Uint8List bytes, {
    int maxSide = 1600,
    int quality = 82,
  }) async {
    if (bytes.lengthInBytes < _skipBelowBytes) return bytes;
    try {
      final out = await compute(
        _shrinkInBackground,
        _Job(bytes, maxSide, quality),
      );
      // Keep the original if something odd made it bigger.
      return out != null && out.lengthInBytes < bytes.lengthInBytes
          ? out
          : bytes;
    } catch (e) {
      debugPrint('Photo shrink failed, sending original: $e');
      return bytes;
    }
  }
}

class _Job {
  const _Job(this.bytes, this.maxSide, this.quality);
  final Uint8List bytes;
  final int maxSide;
  final int quality;
}

Uint8List? _shrinkInBackground(_Job job) {
  var image = img.decodeImage(job.bytes);
  if (image == null) return null;
  // Phone photos are often stored sideways with a "rotate me" tag.
  image = img.bakeOrientation(image);
  final longest = image.width > image.height ? image.width : image.height;
  if (longest > job.maxSide) {
    image = image.width >= image.height
        ? img.copyResize(image, width: job.maxSide)
        : img.copyResize(image, height: job.maxSide);
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: job.quality));
}
