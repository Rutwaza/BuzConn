import 'dart:io';

import 'package:google_sign_in_all_platforms/google_sign_in_all_platforms.dart'
    as desktop_google;

/// Holds the desktop OAuth client for the life of the process. The plugin's
/// platform interface accepts its parameters only once per process.
class WindowsGoogleAuthService {
  WindowsGoogleAuthService._();

  static desktop_google.GoogleSignIn? _client;

  static Future<desktop_google.GoogleSignInCredentials?> signIn() {
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows Google sign-in is only for Windows.');
    }

    const clientId = String.fromEnvironment(
      'WINDOWS_GOOGLE_CLIENT_ID',
      defaultValue:
          '540337503772-9jnkljb4pclng7rqv555mftk06p8gr8l.apps.googleusercontent.com',
    );
    const clientSecret = String.fromEnvironment(
      'WINDOWS_GOOGLE_CLIENT_SECRET',
    );
    if (clientSecret.isEmpty) {
      throw StateError(
        'Windows Google sign-in is not configured. Add WINDOWS_GOOGLE_CLIENT_SECRET and relaunch.',
      );
    }

    final client = _client ??= desktop_google.GoogleSignIn(
      params: const desktop_google.GoogleSignInParams(
        clientId: clientId,
        clientSecret: clientSecret,
        scopes: ['openid', 'profile', 'email'],
        redirectPort: 8000,
      ),
    );
    return client.signInOnline();
  }
}
