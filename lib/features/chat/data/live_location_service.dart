import 'dart:async';

import 'package:geolocator/geolocator.dart';

import 'chat_repository.dart';

/// Reads the phone's position and keeps live-location messages moving.
///
/// Live sharing runs while Duhuze is open (also on other screens). If the app
/// is closed, the pin simply stops moving and the map shows "updated X min
/// ago". Sharing in the background needs an Android foreground service and is
/// a later step.
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

  bool isSharing(String messageId) => _shares.containsKey(messageId);

  /// Starts moving the pin of [messageId] until [until].
  void start({
    required String chatId,
    required String messageId,
    required DateTime until,
  }) {
    stop(messageId, notifyServer: false);
    final share = _LiveShare(chatId, messageId);
    _shares[messageId] = share;

    share.subscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 20, // metres; standing still costs nothing
      ),
    ).listen((p) {
      final now = DateTime.now();
      // At most one write every 15 s, to save data and battery.
      if (share.lastSent != null &&
          now.difference(share.lastSent!) < const Duration(seconds: 15)) {
        return;
      }
      share.lastSent = now;
      unawaited(_repo
          .updateLiveLocation(
            chatId: chatId,
            messageId: messageId,
            lat: p.latitude,
            lng: p.longitude,
            accuracy: p.accuracy,
          )
          .catchError((_) {}));
    }, onError: (_) {});

    final left = until.difference(DateTime.now());
    share.timer = Timer(left.isNegative ? Duration.zero : left, () {
      stop(messageId);
    });
  }

  /// Stops sharing. With [notifyServer] the message is marked as ended so the
  /// other person sees "Live location ended".
  void stop(String messageId, {bool notifyServer = true}) {
    final share = _shares.remove(messageId);
    if (share == null) return;
    share.subscription?.cancel();
    share.timer?.cancel();
    if (notifyServer) {
      unawaited(_repo
          .stopLiveLocation(chatId: share.chatId, messageId: messageId)
          .catchError((_) {}));
    }
  }
}

class _LiveShare {
  _LiveShare(this.chatId, this.messageId);
  final String chatId;
  final String messageId;
  StreamSubscription<Position>? subscription;
  Timer? timer;
  DateTime? lastSent;
}

class LocationProblem implements Exception {
  const LocationProblem(this.message);
  final String message;
  @override
  String toString() => message;
}
