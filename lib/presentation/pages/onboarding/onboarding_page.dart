import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/colors.dart';
import '../../../core/widgets/app_button.dart';

class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key});

  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  final List<OnboardingItem> _onboardingItems = [
    OnboardingItem(
      title: 'Connect with Local Businesses',
      description: 'Discover amazing services and products from businesses near you.',
      icon: Icons.handshake,
    ),
    OnboardingItem(
      title: 'Grow Your Business',
      description: 'Reach potential clients and showcase your services effectively.',
      icon: Icons.trending_up,
    ),
    OnboardingItem(
      title: 'Easy Communication',
      description: 'Chat directly with businesses and get instant responses.',
      icon: Icons.chat,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            itemCount: _onboardingItems.length,
            onPageChanged: (index) {
              setState(() {
                _currentPage = index;
              });
            },
            itemBuilder: (context, index) {
              final item = _onboardingItems[index];
              return _buildPage(item);
            },
          ),
          Positioned(
            top: 48,
            left: 0,
            right: 0,
            child: Center(
              child: GestureDetector(
                onTap: () {
                  context.go(AppRoutes.login);
                },
                child: Image.asset(
                  'assets/images/app_icon.png',
                  height: 64,
                  width: 64,
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 100,
            left: 0,
            right: 0,
            child: Center(
              child: SmoothPageIndicator(
                controller: _pageController,
                count: _onboardingItems.length,
                effect: const WormEffect(
                  dotHeight: 8,
                  dotWidth: 8,
                  activeDotColor: AppColors.primary,
                  dotColor: AppColors.lightGrey,
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 32,
            left: 20,
            right: 20,
            child: Column(
              children: [
                AppButton(
                  text: _currentPage == _onboardingItems.length - 1
                      ? 'Get Started'
                      : 'Next',
                  onPressed: () {
                    if (_currentPage == _onboardingItems.length - 1) {
                      context.go(AppRoutes.login);
                    } else {
                      _pageController.nextPage(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      );
                    }
                  },
                ),
                const SizedBox(height: 12),
                if (_currentPage != _onboardingItems.length - 1)
                  TextButton(
                    onPressed: () {
                      context.go(AppRoutes.login);
                    },
                    child: const Text(
                      'Skip',
                      style: TextStyle(
                        fontSize: 16,
                        color: AppColors.grey,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPage(OnboardingItem item) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          const SizedBox(height: 140),
          Icon(
            item.icon,
            size: 120,
            color: AppColors.primary,
          ),
          const SizedBox(height: 32),
          Text(
            item.title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: AppColors.black,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            item.description,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 16,
              color: AppColors.darkGrey,
              height: 1.5,
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

class OnboardingItem {
  final String title;
  final String description;
  final IconData icon;

  OnboardingItem({
    required this.title,
    required this.description,
    required this.icon,
  });
}
