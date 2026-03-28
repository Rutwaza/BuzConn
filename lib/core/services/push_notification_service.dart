import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'local_notification_service.dart';

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

    await LocalNotificationService.instance.initialize();
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
      final notification = message.notification;
      final title = notification?.title ?? _titleFromData(message.data);
      final body = notification?.body ?? _bodyFromData(message.data);
      if (title.isNotEmpty || body.isNotEmpty) {
        LocalNotificationService.instance.show(
          title: title.isEmpty ? 'SpotLight' : title,
          body: body.isEmpty ? 'You have a new update.' : body,
          payload: {
            'type': message.data['type'],
            'chatId': message.data['chatId'],
            'postId': message.data['postId'],
            'userId': message.data['userId'] ?? message.data['fromUserId'],
          },
        );
      }
      if (kDebugMode) {
        debugPrint('FCM foreground message: ${message.messageId}');
      }
    });

    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      LocalNotificationService.instance.handlePayload({
        'type': message.data['type'],
        'chatId': message.data['chatId'],
        'postId': message.data['postId'],
        'userId': message.data['userId'] ?? message.data['fromUserId'],
      });
    });

    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      LocalNotificationService.instance.handlePayload({
        'type': initialMessage.data['type'],
        'chatId': initialMessage.data['chatId'],
        'postId': initialMessage.data['postId'],
        'userId':
            initialMessage.data['userId'] ?? initialMessage.data['fromUserId'],
      });
    }
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

  String _titleFromData(Map<String, dynamic> data) {
    final type = (data['type'] ?? '').toString();
    final fromName = (data['fromUserName'] ?? 'Someone').toString();
    switch (type) {
      case 'message':
        return fromName;
      case 'follow':
        return 'New follower';
      case 'comment':
        return 'New comment';
      case 'like':
        return 'New like';
      default:
        return 'SpotLight';
    }
  }

  String _bodyFromData(Map<String, dynamic> data) {
    final type = (data['type'] ?? '').toString();
    final fromName = (data['fromUserName'] ?? 'Someone').toString();
    final preview = (data['preview'] ?? '').toString();
    switch (type) {
      case 'message':
        return preview.isEmpty ? '$fromName sent you a message' : preview;
      case 'follow':
        return '$fromName followed you';
      case 'comment':
        return preview.isEmpty
            ? '$fromName commented on your post'
            : preview;
      case 'like':
        return preview.isEmpty ? '$fromName liked your post' : preview;
      default:
        return preview.isEmpty ? 'You have a new update.' : preview;
    }
  }
}
