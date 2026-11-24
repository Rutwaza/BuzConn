import 'package:go_router/go_router.dart';
import 'package:businessfinder/core/i18n/tr.dart';

import '../constants/app_constants.dart';
import 'package:businessfinder/presentation/pages/splash/splash_page.dart';
import 'package:businessfinder/presentation/pages/onboarding/onboarding_page.dart';
import 'package:businessfinder/presentation/pages/auth/login_page.dart';
import 'package:businessfinder/presentation/pages/auth/register_page.dart';
import 'package:businessfinder/presentation/pages/profile/profile_completion_page.dart';
import 'package:businessfinder/presentation/pages/business/business_setup_page.dart';
import 'package:businessfinder/presentation/pages/business/businesses_page.dart';
import 'package:businessfinder/presentation/pages/feed/posts_feed_page.dart';
import 'package:businessfinder/presentation/pages/feed/create_post_page.dart';
import 'package:businessfinder/presentation/pages/business/business_profile_page.dart';
import 'package:businessfinder/features/chat/ui/chat_list_page.dart';
import 'package:businessfinder/features/chat/ui/chat_page.dart';
import 'package:businessfinder/presentation/pages/search/search_page.dart';
import 'package:businessfinder/presentation/pages/profile/client_profile_page.dart';
import 'package:businessfinder/presentation/pages/notifications/notifications_page.dart';
import 'package:businessfinder/presentation/pages/favorites/favorites_page.dart';
import 'package:businessfinder/presentation/pages/analytics/analytics_page.dart';
import 'package:businessfinder/presentation/pages/profile/follow_list_page.dart';
import 'package:businessfinder/presentation/pages/business/page_followers_page.dart';
import 'package:businessfinder/presentation/pages/settings/settings_page.dart';
import 'package:businessfinder/core/widgets/spotlight_loader.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:businessfinder/data/models/post_model.dart';
import 'package:businessfinder/presentation/pages/business/post_detail_page.dart';

class AppRouter {
  static final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  static final GoRouter router = GoRouter(
    initialLocation: AppRoutes.splash,
    routes: [
      GoRoute(
        path: AppRoutes.splash,
        builder: (context, state) => const SplashPage(),
      ),
      GoRoute(
        path: AppRoutes.onboarding,
        builder: (context, state) => const OnboardingPage(),
      ),
      GoRoute(
        path: AppRoutes.login,
        builder: (context, state) => const LoginPage(),
      ),
      GoRoute(
        path: AppRoutes.register,
        builder: (context, state) => const RegisterPage(),
      ),
      GoRoute(
        path: AppRoutes.profile,
        builder: (context, state) => const ProfileCompletionPage(),
      ),
      GoRoute(
        path: AppRoutes.businessSetup,
        builder: (context, state) => BusinessSetupPage(
          editBusinessId: state.uri.queryParameters['businessId'],
        ),
      ),
      GoRoute(
        path: AppRoutes.businesses,
        builder: (context, state) => const BusinessesPage(),
      ),
      GoRoute(
        path: AppRoutes.businessProfile,
        builder: (context, state) =>
            BusinessProfilePage(businessId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: AppRoutes.clientProfile,
        builder: (context, state) =>
            ClientProfilePage(userId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: AppRoutes.notifications,
        builder: (context, state) => const NotificationsPage(),
      ),
      GoRoute(
        path: AppRoutes.feed,
        builder: (context, state) => PostsFeedPage(
          initialPostId: state.uri.queryParameters['postId'],
        ),
      ),
      GoRoute(
        path: AppRoutes.post,
        builder: (context, state) {
          final postId = state.pathParameters['id']!;
          return FutureBuilder<DocumentSnapshot>(
            future: FirebaseFirestore.instance
                .collection('posts')
                .doc(postId)
                .get(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Scaffold(
                  body: Center(child: SpotlightLoader(size: 44)),
                );
              }
              if (!snapshot.data!.exists) {
                return Scaffold(
                  body: Center(child: Text(tr('Post not found'))),
                );
              }
              final post = Post.fromFirestore(snapshot.data!);
              return PostDetailPage(post: post);
            },
          );
        },
      ),
      GoRoute(
        path: AppRoutes.createPost,
        builder: (context, state) => const CreatePostPage(),
      ),
      GoRoute(
        path: AppRoutes.dashboard,
        builder: (context, state) => const PostsFeedPage(),
      ),
      GoRoute(
        path: AppRoutes.search,
        builder: (context, state) => const SearchPage(),
      ),
      GoRoute(
        path: AppRoutes.chats,
        builder: (context, state) => ChatListPage(
          initialFilter: state.uri.queryParameters['filter'],
        ),
      ),
      GoRoute(
        path: AppRoutes.chatDetail,
        builder: (context, state) =>
            ChatPage(chatId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: AppRoutes.favorites,
        builder: (context, state) => const FavoritesPage(),
      ),
      GoRoute(
        path: AppRoutes.analytics,
        builder: (context, state) => const AnalyticsPage(),
      ),
      GoRoute(
        path: AppRoutes.settings,
        builder: (context, state) => const SettingsPage(),
      ),
      GoRoute(
        path: AppRoutes.userFollowers,
        builder: (context, state) => FollowListPage(
          userId: state.pathParameters['id']!,
          type: FollowListType.followers,
        ),
      ),
      GoRoute(
        path: AppRoutes.userFollowing,
        builder: (context, state) => FollowListPage(
          userId: state.pathParameters['id']!,
          type: FollowListType.following,
        ),
      ),
      GoRoute(
        path: AppRoutes.pageFollowers,
        builder: (context, state) => PageFollowersPage(
          pageId: state.pathParameters['id']!,
        ),
      ),
    ],
  );
}
