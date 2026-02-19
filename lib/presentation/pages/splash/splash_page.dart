import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/colors.dart';
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
    // Simulate loading time
    await Future.delayed(const Duration(seconds: 2));

    // Check authentication status
    final isLoggedIn = await FirebaseService.instance.isUserLoggedIn();

    // Navigate based on auth status
    if (mounted) {
      if (isLoggedIn) {
        // Navigate to feed if already logged in
        context.go(AppRoutes.feed);
      } else {
        // Navigate to onboarding if not logged in
        context.go(AppRoutes.onboarding);
      }
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
              child: const Icon(
                Icons.handshake,
                size: 60,
                color: AppColors.primary,
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
              'Connecting Businesses & Clients',
              style: TextStyle(
                fontSize: 16,
                color: AppColors.white.withOpacity(0.8),
              ),
            ),
            const SizedBox(height: 48),
            // Loading Animation
            const CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.white),
            ),
          ],
        ),
      ),
    );
  }
}
