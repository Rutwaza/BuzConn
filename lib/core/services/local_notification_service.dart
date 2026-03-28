import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../constants/app_constants.dart';
import '../routes/router.dart';

class LocalNotificationService {
  LocalNotificationService._();

  static final LocalNotificationService instance = LocalNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  static const AndroidNotificationChannel _chatChannel =
      AndroidNotificationChannel(
    'spotlight_chat',
    'SpotLight Chats',
    description: 'Direct messages and chat alerts.',
    importance: Importance.high,
  );

  static const AndroidNotificationChannel _activityChannel =
      AndroidNotificationChannel(
    'spotlight_activity',
    'SpotLight Activity',
    description: 'Follows, likes, comments, and Spotlight activity.',
    importance: Importance.high,
  );

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();

    await _plugin.initialize(
      const InitializationSettings(
        android: android,
        iOS: ios,
      ),
      onDidReceiveNotificationResponse: _handleNotificationTap,
    );

    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_chatChannel);
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_activityChannel);
  }

  Future<void> show({
    required String title,
    required String body,
    Map<String, dynamic>? payload,
  }) async {
    await initialize();
    final type = (payload?['type'] ?? '').toString();
    final isChat = type == 'message';
    final channel = isChat ? _chatChannel : _activityChannel;
    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: Importance.max,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
          threadIdentifier: isChat ? 'spotlight_chat' : 'spotlight_activity',
        ),
      ),
      payload: payload == null ? null : jsonEncode(payload),
    );
  }

  void _handleNotificationTap(NotificationResponse response) {
    final rawPayload = response.payload;
    if (rawPayload == null || rawPayload.isEmpty) {
      AppRouter.router.push(AppRoutes.notifications);
      return;
    }

    try {
      final payload = jsonDecode(rawPayload) as Map<String, dynamic>;
      final type = (payload['type'] ?? '').toString();
      final chatId = (payload['chatId'] ?? '').toString();
      final postId = (payload['postId'] ?? '').toString();
      final userId = (payload['userId'] ?? '').toString();

      if (type == 'message' && chatId.isNotEmpty) {
        AppRouter.router.push(AppRoutes.chatDetailPath(chatId));
        return;
      }
      if (type == 'follow' && userId.isNotEmpty) {
        AppRouter.router.push(AppRoutes.clientProfilePath(userId));
        return;
      }
      if ((type == 'like' || type == 'comment') && postId.isNotEmpty) {
        AppRouter.router.push(AppRoutes.postPath(postId));
        return;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Local notification payload parse failed: $e');
      }
    }

    AppRouter.router.push(AppRoutes.notifications);
  }

  void handlePayload(Map<String, dynamic> payload) {
    _handleNotificationTap(
      NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotification,
        payload: jsonEncode(payload),
      ),
    );
  }
}
