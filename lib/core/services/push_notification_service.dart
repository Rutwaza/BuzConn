import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

class PushNotificationService {
  PushNotificationService._();

  static final PushNotificationService instance = PushNotificationService._();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  StreamSubscription<User?>? _authSub;
  StreamSubscription<String>? _tokenSub;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    await _requestPermission();
    await _syncCurrentToken();

    _authSub = _auth.authStateChanges().listen((user) async {
      if (user != null) {
        await _syncCurrentToken();
      }
    });

    _tokenSub = _messaging.onTokenRefresh.listen((token) async {
      await _saveToken(token);
    });

    FirebaseMessaging.onMessage.listen((message) {
      if (kDebugMode) {
        debugPrint('FCM foreground message: ${message.messageId}');
      }
    });
  }

  Future<void> _requestPermission() async {
    await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );
  }

  Future<void> _syncCurrentToken() async {
    try {
      final token = await _messaging.getToken();
      if (token != null) {
        await _saveToken(token);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('FCM getToken failed: $e');
      }
    }
  }

  Future<void> _saveToken(String token) async {
    final user = _auth.currentUser;
    if (user == null) return;
    await _firestore.collection('users').doc(user.uid).set({
      'fcmTokens': FieldValue.arrayUnion([token]),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> dispose() async {
    await _authSub?.cancel();
    await _tokenSub?.cancel();
  }
}
