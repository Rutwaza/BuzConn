import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../../../core/constants/app_constants.dart';

/// "Online" and "typing…" live in the Realtime Database, not Firestore.
///
/// Why: these values change many times a minute. In Firestore every change is
/// a paid write and it also woke up the chat list of both people. The
/// Realtime Database is made for tiny, fast-changing values, and its
/// `onDisconnect()` clears them by itself when a phone loses network.
///
/// Paths (see database.rules.json):
///   status/{uid}            {state: 'online'|'offline', lastChanged}
///   typing/{chatId}/{uid}   true while typing (removed when stopped)
class PresenceService {
  PresenceService._();

  static final PresenceService instance = PresenceService._();

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
      if (user != null) _trackOnline(user.uid);
    });
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
    try {
      await db.ref('status/$uid').set({
        'state': 'offline',
        'lastChanged': ServerValue.timestamp,
      });
    } catch (_) {}
  }

  /// Online status of another user. Emits (isOnline, lastSeen).
  Stream<({bool isOnline, DateTime? lastSeen})> watchStatus(String uid) {
    return db.ref('status/$uid').onValue.map((event) {
      final value = event.snapshot.value;
      if (value is! Map) return (isOnline: false, lastSeen: null);
      final millis = value['lastChanged'];
      return (
        isOnline: value['state'] == 'online',
        lastSeen: millis is int
            ? DateTime.fromMillisecondsSinceEpoch(millis)
            : null,
      );
    });
  }

  Future<void> setTyping(String chatId, bool isTyping) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
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
    return db
        .ref('typing/$chatId/$otherUid')
        .onValue
        .map((event) => event.snapshot.value == true);
  }
}
