import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:win_toast/win_toast.dart';

import 'local_notification_service.dart';

class PushNotificationService {
  PushNotificationService._();

  static final PushNotificationService instance = PushNotificationService._();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  StreamSubscription<User?>? _authSub;
  StreamSubscription<String>? _tokenSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
      _windowsNotificationsSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _windowsCallSub;
  static const MethodChannel _windowsCallChannel =
      MethodChannel('spotlight/calls');
  bool _initialized = false;
  bool _windowsToastReady = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    if (Platform.isWindows) {
      try {
        _windowsToastReady = await WinToast.instance().initialize(
          aumId: 'BuzConn.Duhuze',
          displayName: 'Duhuze',
          iconPath: '',
          clsid: 'D926593C-9EBD-4E8B-A6DD-4905854EE387',
        );
        WinToast.instance().setActivatedCallback((event) {
          try {
            final payload = jsonDecode(event.argument) as Map<String, dynamic>;
            LocalNotificationService.instance.handlePayload(payload);
          } catch (error) {
            if (kDebugMode) debugPrint('Windows toast activation failed: $error');
          }
        });
      } catch (error) {
        if (kDebugMode) debugPrint('Windows toast initialization failed: $error');
      }
      _authSub = _auth.authStateChanges().listen(_handleWindowsAuthChange);
      return;
    }

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
          title: title.isEmpty ? 'Duhuze' : title,
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

  Future<void> _handleWindowsAuthChange(User? user) async {
    await _windowsNotificationsSub?.cancel();
    _windowsNotificationsSub = null;
    await _windowsCallSub?.cancel();
    _windowsCallSub = null;
    await _setWindowsRinging(false);
    if (user == null) return;

    var isInitialSnapshot = true;
    _windowsNotificationsSub = _firestore
        .collection('notifications')
        .where('toUserId', isEqualTo: user.uid)
        .orderBy('createdAt', descending: true)
        .limit(20) // only new ones matter here
        .snapshots()
        .listen((snapshot) {
      if (isInitialSnapshot) {
        isInitialSnapshot = false;
        return;
      }
      for (final change in snapshot.docChanges) {
        if (change.type != DocumentChangeType.added) continue;
        final data = change.doc.data();
        if (data == null) continue;
        _showWindowsNotification(data);
      }
    }, onError: (Object error) {
      if (kDebugMode) debugPrint('Windows notification listener failed: $error');
    });
  }

  void _showWindowsNotification(Map<String, dynamic> data) {
    final type = (data['type'] ?? '').toString();
    final chatId = (data['chatId'] ?? '').toString();
    final title = _titleFromData(data);
    final body = _bodyFromData(data);
    if (type == 'call' && chatId.isNotEmpty) {
      _watchWindowsCall(chatId);
    }

    if (!_windowsToastReady) return;
    final safeTitle = _escapeToastText(title);
    final safeBody = _escapeToastText(body);
    final launchPayload = jsonEncode({
      'type': type,
      'chatId': chatId,
      'postId': data['postId'],
      'userId': data['fromUserId'],
    });
    unawaited(_showWindowsToast(
      safeTitle,
      safeBody,
      _escapeToastText(launchPayload),
    ));
  }

  Future<void> _showWindowsToast(
    String title,
    String body,
    String launchPayload,
  ) async {
    try {
      await WinToast.instance().showCustomToast(
        xml: '''<?xml version="1.0" encoding="UTF-8"?>
<toast duration="long" launch="$launchPayload"><visual><binding template="ToastGeneric">
<text>$title</text><text>$body</text>
</binding></visual></toast>''',
      );
    } catch (error) {
      if (kDebugMode) debugPrint('Windows toast display failed: $error');
    }
  }

  String _escapeToastText(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  void _watchWindowsCall(String chatId) {
    unawaited(_windowsCallSub?.cancel());
    _windowsCallSub = _firestore
        .collection('chats')
        .doc(chatId)
        .collection('calls')
        .doc('active')
        .snapshots()
        .listen((snapshot) {
      final data = snapshot.data();
      final isIncoming = snapshot.exists &&
          data?['status'] == 'calling' &&
          data?['callerId'] != _auth.currentUser?.uid;
      unawaited(_setWindowsRinging(isIncoming));
    });
  }

  Future<void> _setWindowsRinging(bool enabled) async {
    try {
      await _windowsCallChannel.invokeMethod<void>(
        'setRinging',
        {'enabled': enabled},
      );
    } catch (_) {}
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
    // Device tokens are private: users_private/{uid} can only be read by its
    // owner (and the server, which sends the pushes).
    await _firestore.collection('users_private').doc(user.uid).set({
      'fcmTokens': FieldValue.arrayUnion([token]),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> dispose() async {
    await _authSub?.cancel();
    await _tokenSub?.cancel();
    await _windowsNotificationsSub?.cancel();
    await _windowsCallSub?.cancel();
    await _setWindowsRinging(false);
  }

  String _titleFromData(Map<String, dynamic> data) {
    final type = (data['type'] ?? '').toString();
    final fromName = (data['fromUserName'] ?? 'Someone').toString();
    switch (type) {
      case 'message':
        return fromName;
      case 'message_request':
        return 'Message request';
      case 'call':
        return 'Incoming call';
      case 'follow':
        return 'New follower';
      case 'comment':
        return 'New comment';
      case 'like':
        return 'New like';
      default:
        return 'Duhuze';
    }
  }

  String _bodyFromData(Map<String, dynamic> data) {
    final type = (data['type'] ?? '').toString();
    final fromName = (data['fromUserName'] ?? 'Someone').toString();
    final preview = (data['preview'] ?? '').toString();
    switch (type) {
      case 'message':
        return preview.isEmpty ? '$fromName sent you a message' : preview;
      case 'message_request':
        return '$fromName wants to message you';
      case 'call':
        return '$fromName is calling you';
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
