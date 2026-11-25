import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show AppExitResponse;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../core/constants/app_constants.dart';
import 'rtdb_rest.dart';

/// "Online" and "typing…" live in the Realtime Database, not Firestore.
///
/// Why: these values change many times a minute. In Firestore every change is
/// a paid write and it also woke up the chat list of both people. The
/// Realtime Database is made for tiny, fast-changing values, and its
/// `onDisconnect()` clears them by itself when a phone loses network.
///
/// Paths (see database.rules.json):
///   status/{uid}            {state: 'online'|'offline', lastChanged, client?}
///   typing/{chatId}/{uid}   true while typing (removed when stopped)
///
/// Windows: the firebase_database plugin does not exist there, so the desktop
/// app uses the REST API (rtdb_rest.dart). REST has no onDisconnect(), so the
/// desktop writes `client: 'desktop'` and repeats "online" every minute;
/// everyone treats a desktop that went quiet for [desktopStaleAfter] as
/// offline. Closing the window marks it offline at once.
class PresenceService {
  PresenceService._();

  static final PresenceService instance = PresenceService._();

  static final bool _rest = !kIsWeb && Platform.isWindows;
  static const desktopStaleAfter = Duration(minutes: 3);
  static const _heartbeat = Duration(minutes: 1);
  Timer? _heartbeatTimer;
  AppLifecycleListener? _exitListener;

  FirebaseDatabase? _db;
  StreamSubscription<User?>? _authSub;
  StreamSubscription<DatabaseEvent>? _connectedSub;

  FirebaseDatabase get db => _db ??= FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: AppConstants.realtimeDatabaseUrl,
      );

  /// Call once after Firebase is initialised.
  void start() {
    _authSub ??= FirebaseAuth.instance.authStateChanges().listen((user) {
      _connectedSub?.cancel();
      _connectedSub = null;
      _heartbeatTimer?.cancel();
      if (user == null) return;
      if (_rest) {
        _trackOnlineDesktop(user.uid);
      } else {
        _trackOnline(user.uid);
      }
    });
    if (_rest) {
      // Closing the Duhuze window: show offline before the app quits.
      _exitListener ??= AppLifecycleListener(onExitRequested: () async {
        await goOffline().timeout(const Duration(seconds: 2), onTimeout: () {});
        return AppExitResponse.exit;
      });
    }
  }

  void _trackOnlineDesktop(String uid) {
    Future<void> beat() async {
      try {
        await RtdbRest.instance.put('status/$uid', {
          'state': 'online',
          'lastChanged': RtdbRest.serverTimestamp,
          'client': 'desktop',
        });
      } catch (e) {
        debugPrint('Presence (desktop) failed: $e');
      }
    }

    beat();
    _heartbeatTimer = Timer.periodic(_heartbeat, (_) => beat());
  }

  void _trackOnline(String uid) {
    final statusRef = db.ref('status/$uid');
    _connectedSub = db.ref('.info/connected').onValue.listen((event) async {
      if (event.snapshot.value != true) return;
      try {
        // Ask the server to mark us offline the moment the connection drops,
        // then mark us online.
        await statusRef.onDisconnect().set({
          'state': 'offline',
          'lastChanged': ServerValue.timestamp,
        });
        await statusRef.set({
          'state': 'online',
          'lastChanged': ServerValue.timestamp,
        });
      } catch (e) {
        debugPrint('Presence update failed: $e');
      }
    });
  }

  /// Call before signing out so the user shows offline at once.
  Future<void> goOffline() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _heartbeatTimer?.cancel();
    try {
      if (_rest) {
        await RtdbRest.instance.put('status/$uid', {
          'state': 'offline',
          'lastChanged': RtdbRest.serverTimestamp,
          'client': 'desktop',
        });
        return;
      }
      await db.ref('status/$uid').set({
        'state': 'offline',
        'lastChanged': ServerValue.timestamp,
      });
    } catch (_) {}
  }

  /// Online status of another user. Emits (isOnline, lastSeen).
  Stream<({bool isOnline, DateTime? lastSeen})> watchStatus(String uid) {
    final Stream<Object?> raw = _rest
        ? RtdbRest.instance.watch('status/$uid')
        : db.ref('status/$uid').onValue.map((e) => e.snapshot.value);
    return raw.asyncExpand((value) async* {
      yield _parseStatus(value);
      // A desktop that stops sending heartbeats goes "offline" by itself.
      if (value is Map && value['client'] == 'desktop' && value['state'] == 'online') {
        final last = _parseStatus(value).lastSeen;
        if (last != null) {
          final left = desktopStaleAfter - DateTime.now().difference(last);
          if (left > Duration.zero) await Future<void>.delayed(left);
          yield _parseStatus(value);
        }
      }
    });
  }

  ({bool isOnline, DateTime? lastSeen}) _parseStatus(Object? value) {
    if (value is! Map) return (isOnline: false, lastSeen: null);
    final millis = value['lastChanged'];
    final lastSeen =
        millis is num ? DateTime.fromMillisecondsSinceEpoch(millis.toInt()) : null;
    var online = value['state'] == 'online';
    if (online && value['client'] == 'desktop' && lastSeen != null &&
        DateTime.now().difference(lastSeen) > desktopStaleAfter) {
      online = false;
    }
    return (isOnline: online, lastSeen: lastSeen);
  }

  Future<void> setTyping(String chatId, bool isTyping) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    if (_rest) {
      try {
        if (isTyping) {
          await RtdbRest.instance.put('typing/$chatId/$uid', true);
        } else {
          await RtdbRest.instance.delete('typing/$chatId/$uid');
        }
      } catch (e) {
        debugPrint('Typing (desktop) failed: $e');
      }
      return;
    }
    final ref = db.ref('typing/$chatId/$uid');
    try {
      if (isTyping) {
        await ref.onDisconnect().remove();
        await ref.set(true);
      } else {
        await ref.remove();
      }
    } catch (e) {
      debugPrint('Typing update failed: $e');
    }
  }

  /// True while [otherUid] is typing in [chatId].
  Stream<bool> watchTyping(String chatId, String otherUid) {
    if (_rest) {
      return RtdbRest.instance.watch('typing/$chatId/$otherUid').map((v) => v == true);
    }
    return db
        .ref('typing/$chatId/$otherUid')
        .onValue
        .map((event) => event.snapshot.value == true);
  }
}
