import 'package:go_router/go_router.dart';

import '../constants/app_constants.dart';
import '../../presentation/pages/splash/splash_page.dart';
import '../../presentation/pages/onboarding/onboarding_page.dart';
import '../../presentation/pages/auth/login_page.dart';
import '../../presentation/pages/auth/register_page.dart';
import '../../presentation/pages/profile/profile_completion_page.dart';
import '../../presentation/pages/business/business_setup_page.dart';
import '../../presentation/pages/business/businesses_page.dart';
import '../../presentation/pages/feed/posts_feed_page.dart';
import '../../presentation/pages/feed/create_post_page.dart';
import '../../presentation/pages/business/business_profile_page.dart';
import '../../presentation/pages/traffic/traffic_management_page.dart';
import '../../presentation/pages/chat/chat_list_page.dart';
import '../../presentation/pages/chat/chat_page.dart';
import '../../presentation/pages/search/search_page.dart';
import '../../presentation/pages/profile/client_profile_page.dart';
import '../../presentation/pages/notifications/notifications_page.dart';
import '../../features/dashboard/dashboard_page.dart';

class AppRouter {
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
        builder: (context, state) => const BusinessSetupPage(),
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
        builder: (context, state) => const PostsFeedPage(),
      ),
      GoRoute(
        path: AppRoutes.createPost,
        builder: (context, state) => const CreatePostPage(),
      ),
      GoRoute(
        path: AppRoutes.dashboard,
        builder: (context, state) => const DashboardPage(),
      ),
      GoRoute(
        path: AppRoutes.search,
        builder: (context, state) => const SearchPage(),
      ),
      GoRoute(
        path: AppRoutes.trafficManagement,
        builder: (context, state) => const TrafficManagementPage(),
      ),
      GoRoute(
        path: AppRoutes.chats,
        builder: (context, state) => const ChatListPage(),
      ),
      GoRoute(
        path: AppRoutes.chatDetail,
        builder: (context, state) =>
            ChatPage(chatId: state.pathParameters['id']!),
      ),
    ],
  );
}
