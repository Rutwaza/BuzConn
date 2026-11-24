import 'package:flutter/material.dart';
import 'package:businessfinder/core/i18n/tr.dart';
import 'dart:ui';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:media_kit/media_kit.dart';

import 'core/theme/app_theme.dart';
import 'core/services/firebase_service.dart';
import 'core/services/push_notification_service.dart';
import 'core/services/theme_mode_service.dart';
import 'core/routes/router.dart';
import 'features/chat/data/presence_service.dart';
import 'core/widgets/network_status_banner.dart';
import 'core/widgets/night_sky_background.dart';
import 'firebase_options.dart';

Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.dumpErrorToConsole(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Uncaught error: $error\n$stack');
    return true;
  };

  // Initialize MediaKit for cross-platform video playback (only on Windows)
  if (Platform.isWindows) {
    MediaKit.ensureInitialized();
  }

  // Initialize Firebase
  await FirebaseService.instance.initialize();
  if (Platform.isAndroid) {
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  }

  runApp(
    const ProviderScope(
      child: MyApp(),
    ),
  );

  // Defer non-critical startup work until after the first frame.
  Future(() async {
    PresenceService.instance.start();
    await PushNotificationService.instance.initialize();
    await ThemeModeService.instance.loadFromUser();
    await LanguageService.instance.loadFromUser();
  });
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ValueListenableBuilder<AppThemeMode>(
      valueListenable: ThemeModeService.instance.mode,
      builder: (context, mode, _) {
        final themeMode =
            mode == AppThemeMode.dark ? ThemeMode.dark : ThemeMode.light;
        return MaterialApp.router(
          title: tr('Duhuze'),
          scaffoldMessengerKey: AppRouter.scaffoldMessengerKey,
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: themeMode,
          builder: (context, child) {
            final content = NetworkStatusBanner(
              child: child ?? const SizedBox.shrink(),
            );
            if (mode == AppThemeMode.light) {
              return content;
            }
            return Stack(
              children: [
                const Positioned.fill(
                  child: IgnorePointer(
                    child: NightSkyBackground(),
                  ),
                ),
                content,
              ],
            );
          },
          routerConfig: AppRouter.router,
        );
      },
    );
  }
}
