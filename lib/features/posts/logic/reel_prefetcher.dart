import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Downloads the next reels in the background so swiping up starts playback
/// at once (Phase 3). Videos are kept in a small on-phone cache.
class ReelPrefetcher {
  ReelPrefetcher._();

  static final CacheManager _cache = CacheManager(
    Config(
      'duhuze_reels',
      stalePeriod: const Duration(days: 3),
      maxNrOfCacheObjects: 40, // about 40 short videos
    ),
  );

  static final Set<String> _inFlight = <String>{};

  /// Start downloading [urls] (usually the next 2 reels). Safe to call often.
  static void prefetch(Iterable<String> urls) {
    if (kIsWeb) return;
    for (final url in urls) {
      if (url.isEmpty || _inFlight.contains(url)) continue;
      _inFlight.add(url);
      unawaited(
        _cache
            .getSingleFile(url) // uses the cached copy if we already have it
            .then((_) {}, onError: (Object e) {
              debugPrint('Reel prefetch failed: $e');
            })
            .whenComplete(() => _inFlight.remove(url)),
      );
    }
  }

  /// The downloaded file for [url], if it is already on the phone.
  static Future<File?> cachedFile(String url) async {
    if (kIsWeb) return null;
    try {
      final info = await _cache.getFileFromCache(url);
      return info?.file;
    } catch (_) {
      return null;
    }
  }
}
