import 'dart:async';
import 'dart:io' show Platform;

import 'package:geolocator/geolocator.dart';

import 'chat_repository.dart';

/// Reads the phone's position and keeps live-location messages moving.
///
/// One position stream feeds every live share. On Android it runs as a
/// foreground service with a "Sharing live location" notification, so it
/// keeps going when Duhuze is in the background or the screen is off. If the
/// user swipes the app away, Android stops it; the map then shows "updated X
/// min ago", and sharing resumes the next time that chat is opened.
class LiveLocationService {
  LiveLocationService._();
  static final LiveLocationService instance = LiveLocationService._();

  final ChatRepository _repo = ChatRepository();
  final Map<String, _LiveShare> _shares = {};

  /// Asks for permission if needed and returns the current position, or
  /// throws a [LocationProblem] with a message that can be shown to the user.
  static Future<Position> currentPosition() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const LocationProblem('Turn on Location (GPS) on your phone first.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      throw const LocationProblem(
          'Location is blocked for Duhuze. Allow it in your phone settings.');
    }
    if (permission == LocationPermission.denied) {
      throw const LocationProblem('Location permission was not given.');
    }
    return Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
      timeLimit: const Duration(seconds: 20),
    );
  }

  /// A stream of the phone's position for maps (the "me" dot).
  static Stream<Position> positionStream() => Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
        ),
      );

  StreamSubscription<Position>? _stream;

  bool isSharing(String messageId) => _shares.containsKey(messageId);

  /// Starts moving the pin of [messageId] until [until].
  void start({
    required String chatId,
    required String messageId,
    required DateTime until,
  }) {
    final old = _shares.remove(messageId);
    old?.timer?.cancel();
    final share = _LiveShare(chatId, messageId);
    _shares[messageId] = share;
    final left = until.difference(DateTime.now());
    share.timer = Timer(left.isNegative ? Duration.zero : left, () {
      stop(messageId);
    });
    _ensureStream();
  }

  /// Stops sharing. With [notifyServer] the message is marked as ended so the
  /// other person sees "Live location ended".
  void stop(String messageId, {bool notifyServer = true}) {
    final share = _shares.remove(messageId);
    if (share == null) return;
    share.timer?.cancel();
    if (notifyServer) {
      unawaited(_repo
          .stopLiveLocation(chatId: share.chatId, messageId: messageId)
          .catchError((_) {}));
    }
    if (_shares.isEmpty) {
      _stream?.cancel(); // also removes the Android notification
      _stream = null;
    }
  }

  void _ensureStream() {
    if (_stream != null) return;
    _stream = Geolocator.getPositionStream(locationSettings: _liveSettings())
        .listen(_onPosition, onError: (_) {});
  }

  void _onPosition(Position p) {
    final now = DateTime.now();
    for (final share in _shares.values.toList()) {
      // At most one write every 15 s per share, to save data and battery.
      if (share.lastSent != null &&
          now.difference(share.lastSent!) < const Duration(seconds: 15)) {
        continue;
      }
      share.lastSent = now;
      unawaited(_repo
          .updateLiveLocation(
            chatId: share.chatId,
            messageId: share.messageId,
            lat: p.latitude,
            lng: p.longitude,
            accuracy: p.accuracy,
          )
          .catchError((_) {}));
    }
  }

  static LocationSettings _liveSettings() {
    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 20, // metres; standing still costs nothing
        intervalDuration: const Duration(seconds: 15),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Sharing live location',
          notificationText: 'Duhuze is sharing your location in a chat.',
          notificationChannelName: 'Live location',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 20,
    );
  }
}

class _LiveShare {
  _LiveShare(this.chatId, this.messageId);
  final String chatId;
  final String messageId;
  Timer? timer;
  DateTime? lastSent;
}

class LocationProblem implements Exception {
  const LocationProblem(this.message);
  final String message;
  @override
  String toString() => message;
}
