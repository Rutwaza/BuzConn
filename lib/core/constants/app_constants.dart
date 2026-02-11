class AppConstants {
  // App Info
  static const String appName = 'Business Connector';
  static const String appVersion = '1.0.0';
  
  // Storage Keys
  static const String tokenKey = 'auth_token';
  static const String userKey = 'user_data';
  static const String localeKey = 'app_locale';
  static const String themeKey = 'app_theme';
  
  // API Constants
  static const int receiveTimeout = 15000;
  static const int connectTimeout = 15000;
  static const int sendTimeout = 15000;
  
  // Pagination
  static const int defaultPageSize = 10;
  static const int maxImageSize = 5 * 1024 * 1024; // 5MB
  
  // Validation
  static const int minPasswordLength = 8;
  static const int maxBusinessNameLength = 100;
  static const int maxDescriptionLength = 1000;
}

class AppRoutes {
  static const String splash = '/';
  static const String onboarding = '/onboarding';
  static const String login = '/login';
  static const String register = '/register';
  static const String roleSelection = '/role-selection';
  static const String businessSetup = '/business-setup';
  static const String clientSetup = '/client-setup';
  static const String home = '/home';
  static const String dashboard = '/dashboard';
  static const String search = '/search';
  static const String messages = '/messages';
  static const String profile = '/profile';
  static const String settings = '/settings';
  static const String feed = '/feed';
  static const String createPost = '/create-post';
  static const String businesses = '/businesses';
  static const String trafficManagement = '/traffic-management';
  static const String businessProfile = '/business/:id';
  static const String clientProfile = '/user/:id';
  static const String notifications = '/notifications';
  static const String chats = '/chats';
  static const String chatDetail = '/chats/:id';

  static String businessProfilePath(String id) => '/business/$id';
  static String clientProfilePath(String id) => '/user/$id';
  static String chatDetailPath(String id) => '/chats/$id';
}

class AppAssets {
  // Images
  static const String logo = 'assets/images/logo.png';
  static const String onboarding1 = 'assets/images/onboarding1.png';
  static const String onboarding2 = 'assets/images/onboarding2.png';
  static const String onboarding3 = 'assets/images/onboarding3.png';
  static const String placeholder = 'assets/images/placeholder.png';
  
  // Icons
  static const String google = 'assets/icons/google.svg';
  static const String apple = 'assets/icons/apple.svg';
  static const String facebook = 'assets/icons/facebook.svg';
  
  // Animations
  static const String loading = 'assets/animations/loading.json';
  static const String success = 'assets/animations/success.json';
  static const String empty = 'assets/animations/empty.json';
}
