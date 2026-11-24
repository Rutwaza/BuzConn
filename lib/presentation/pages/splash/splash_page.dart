import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/colors.dart';
import '../../../core/widgets/spotlight_loader.dart';
import '../../../core/services/firebase_service.dart';

class SplashPage extends ConsumerStatefulWidget {
  const SplashPage({super.key});

  @override
  ConsumerState<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends ConsumerState<SplashPage> {
  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    print('Splash: Starting initialization');
    // Simulate loading time
    await Future.delayed(const Duration(seconds: 2));
    print('Splash: Delay done');

    // Check authentication status
    final isLoggedIn = await FirebaseService.instance.isUserLoggedIn();
    print('Splash: isLoggedIn = $isLoggedIn');

    // Navigate based on auth status
    if (mounted) {
      if (isLoggedIn) {
        // Navigate to feed if already logged in
        print('Splash: Navigating to feed');
        context.go(AppRoutes.feed);
      } else {
        // Navigate to onboarding if not logged in
        print('Splash: Navigating to onboarding');
        context.go(AppRoutes.onboarding);
      }
    } else {
      print('Splash: Not mounted');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primary,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // App Logo/Icon
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 20,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Image.asset(
                  'assets/images/duhuze_logo.png',
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(height: 32),
            // App Name
            const Text(
              AppConstants.appName,
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w700,
                color: AppColors.white,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 8),
            // Tagline
            Text(
              'Africa Connected.',
              style: TextStyle(
                fontSize: 16,
                color: AppColors.white.withOpacity(0.8),
              ),
            ),
            const SizedBox(height: 48),
            // Loader
            const SpotlightLoader(size: 42, color: AppColors.white),
          ],
        ),
      ),
    );
  }
}
