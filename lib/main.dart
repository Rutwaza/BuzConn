import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'core/theme/app_theme.dart';
import 'core/services/firebase_service.dart';
import 'core/services/push_notification_service.dart';
import 'core/services/theme_mode_service.dart';
import 'core/routes/router.dart';
import 'core/widgets/network_status_banner.dart';
import 'firebase_options.dart';

Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize Firebase
  await FirebaseService.instance.initialize();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // Initialize Supabase
  await Supabase.initialize(
    url: 'https://zzisdifibmelvozmoybv.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inp6aXNkaWZpYm1lbHZvem1veWJ2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAzODUwNDQsImV4cCI6MjA4NTk2MTA0NH0.kiCExd0zlXFmZ_iSg2MB2-MAdJGkXRbVyhGGW4Vuq34',
  );
  
  runApp(
    const ProviderScope(
      child: MyApp(),
    ),
  );

  // Defer non-critical startup work until after the first frame.
  Future(() async {
    await PushNotificationService.instance.initialize();
    await ThemeModeService.instance.loadFromUser();
  });
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ValueListenableBuilder<AppThemeMode>(
      valueListenable: ThemeModeService.instance.mode,
      builder: (context, mode, _) {
        final isCyber = mode == AppThemeMode.cyber;
        final themeMode =
            mode == AppThemeMode.dark ? ThemeMode.dark : ThemeMode.light;
        return MaterialApp.router(
          title: 'Business Connector',
          debugShowCheckedModeBanner: false,
          theme: isCyber ? AppTheme.cyberpunkTheme : AppTheme.lightTheme,
          darkTheme: isCyber ? AppTheme.cyberpunkTheme : AppTheme.darkTheme,
          themeMode: themeMode,
          builder: (context, child) {
            final content = NetworkStatusBanner(
              child: child ?? const SizedBox.shrink(),
            );
            if (mode == AppThemeMode.light) {
              return content;
            }
            final mq = MediaQuery.of(context);
            final dpr = mq.devicePixelRatio;
            final cacheWidth = (mq.size.width * dpr).round();
            final cacheHeight = (mq.size.height * dpr).round();
            return Stack(
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: RepaintBoundary(
                      child: Opacity(
                        opacity: 0.25,
                        child: Image.asset(
                          'assets/images/chat_bg.gif',
                          fit: BoxFit.cover,
                          alignment: Alignment.center,
                          filterQuality: FilterQuality.low,
                          gaplessPlayback: true,
                          cacheWidth: cacheWidth,
                          cacheHeight: cacheHeight,
                        ),
                      ),
                    ),
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
