import 'dart:io';
import 'package:businessfinder/core/i18n/tr.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter/services.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/colors.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/night_sky_background.dart';
import '../../../core/widgets/spotlight_toast.dart';
import '../../../core/services/windows_google_auth_service.dart';
import 'email_verification_notice.dart';
import 'phone_sign_in_sheet.dart';
import 'windows_auth_layout.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _showPassword = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _isLoading = true;
      });

      var didSignIn = false;
      try {
        // Firebase authentication
        final credential =
            await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text.trim(),
        );
        didSignIn = true;

        final user = credential.user;
        final isEmailPasswordUser =
            user?.providerData.any((info) => info.providerId == 'password') ??
                false;
        if (user != null && isEmailPasswordUser && !user.emailVerified) {
          var verificationSent = false;
          try {
            await user.sendEmailVerification();
            verificationSent = true;
          } catch (_) {}
          await FirebaseAuth.instance.signOut();
          didSignIn = false;
          if (mounted) setState(() => _isLoading = false);
          if (mounted) {
            await showEmailVerificationNotice(
              context,
              email: user.email ?? _emailController.text.trim(),
              emailSent: verificationSent,
            );
          }
          return;
        }
        final isProfileComplete =
            user == null ? false : await _ensureUserDocument(user);

        if (!mounted) return;
        setState(() {
          _isLoading = false;
        });

        // Navigate to feed after successful login
        context.go(
          isProfileComplete ? AppRoutes.dashboard : AppRoutes.profile,
        );
      } on FirebaseAuthException catch (e) {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }

        String errorMessage = 'An error occurred';
        if (e.code == 'user-not-found') {
          errorMessage = 'No user found with this email.';
        } else if (e.code == 'wrong-password') {
          errorMessage = 'Wrong password provided.';
        } else if (e.code == 'invalid-email') {
          errorMessage = 'Invalid email address.';
        } else if (e.code == 'invalid-credential') {
          errorMessage = 'Invalid credentials.';
        }

        if (didSignIn && mounted) {
          context.go(AppRoutes.profile);
          return;
        }
        if (mounted) {
          showSpotlightToast(context, errorMessage, success: false);
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }

        if (didSignIn && mounted) {
          context.go(AppRoutes.profile);
          return;
        }
        if (mounted) {
          showSpotlightToast(context, 'Unexpected error: $e', success: false);
        }
      }
    }
  }

  Future<bool> _ensureUserDocument(
    User user, {
    String? name,
    String? email,
    String? phone,
  }) async {
    final doc = FirebaseFirestore.instance.collection('users').doc(user.uid);
    final snapshot = await doc.get();
    final normalizedEmail = (email ?? user.email ?? '').toLowerCase();
    if (snapshot.exists) {
      await doc.set({
        if (normalizedEmail.isNotEmpty) 'emailLower': normalizedEmail,
      }, SetOptions(merge: true));
      final data = snapshot.data() ?? <String, dynamic>{};
      return data['profileCompleted'] == true;
    }
    await doc.set({
      'name': name ?? user.displayName ?? 'User',
      'email': email ?? user.email,
      'emailLower': normalizedEmail,
      'phone': phone ?? user.phoneNumber,
      'createdAt': FieldValue.serverTimestamp(),
      'userType': 'client',
      'themeMode': 'dark',
      'profileCompleted': false,
    });
    return false;
  }

  Future<void> _handleGoogleSignIn() async {
    setState(() {
      _isLoading = true;
    });
    try {
      if (Platform.isWindows) {
        final googleTokens = await WindowsGoogleAuthService.signIn();
        if (googleTokens?.accessToken == null) return;
        final credential = GoogleAuthProvider.credential(
          accessToken: googleTokens!.accessToken,
          idToken: googleTokens.idToken,
        );
        final result = await FirebaseAuth.instance.signInWithCredential(
          credential,
        );
        final user = result.user;
        final isProfileComplete =
            user == null ? false : await _ensureUserDocument(user);
        if (mounted && user != null) {
          context.go(
            isProfileComplete ? AppRoutes.dashboard : AppRoutes.profile,
          );
        }
        return;
      }
      final googleUser = await GoogleSignIn().signIn();
      if (googleUser == null) {
        setState(() {
          _isLoading = false;
        });
        return;
      }
      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      final userCredential =
          await FirebaseAuth.instance.signInWithCredential(credential);
      final user = userCredential.user;
      var isProfileComplete = false;
      if (user != null) {
        isProfileComplete = await _ensureUserDocument(
          user,
          name: user.displayName ?? googleUser.displayName,
          email: user.email ?? googleUser.email,
        );
      }
      if (mounted) {
        context.go(
          isProfileComplete ? AppRoutes.dashboard : AppRoutes.profile,
        );
      }
    } on FirebaseAuthException catch (e) {
      showSpotlightToast(
        context,
        e.message ?? 'Google sign-in failed',
        success: false,
      );
    } catch (error, stackTrace) {
      debugPrint('Google sign-in failed: $error\n$stackTrace');
      showSpotlightToast(
        context,
        'Google sign-in failed: $error',
        success: false,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _handlePhoneSignIn() async {
    if (Platform.isWindows) {
      showSpotlightToast(
        context,
        'Phone verification is currently available in the Android app only.',
        success: false,
      );
      return;
    }
    final credential = await showPhoneSignInSheet(context);
    final user = credential?.user;
    if (user == null || !mounted) return;

    setState(() => _isLoading = true);
    try {
      final isProfileComplete = await _ensureUserDocument(
        user,
        phone: user.phoneNumber,
      );
      if (mounted) {
        context.go(
          isProfileComplete ? AppRoutes.dashboard : AppRoutes.profile,
        );
      }
    } catch (error) {
      if (mounted) {
        showSpotlightToast(
          context,
          'Signed in, but we could not load your profile. Please try again.',
          success: false,
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _showForgotPasswordDialog() async {
    final emailController = TextEditingController(
      text: _emailController.text.trim(),
    );
    var isSending = false;
    String? errorText;
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            icon: const Icon(Icons.mark_email_read_outlined),
            title: Text(tr('Reset your password')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('Enter the email on your account. We will send a secure reset link if the address is registered.'),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: emailController,
                  autofocus: true,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.send,
                  decoration: InputDecoration(
                    labelText: tr('Email address'),
                    hintText: tr('you@example.com'),
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.alternate_email_rounded),
                  ),
                ),
                if (errorText != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    errorText!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: isSending
                    ? null
                    : () => Navigator.of(dialogContext).pop(),
                child: Text(tr('Cancel')),
              ),
              FilledButton(
                onPressed: isSending
                    ? null
                    : () async {
                        final email = emailController.text.trim();
                        if (email.isEmpty ||
                            !RegExp(r'^[^@]+@[^@]+\.[^@]+$')
                                .hasMatch(email)) {
                          setDialogState(() {
                            errorText = 'Enter a valid email address.';
                          });
                          return;
                        }
                        setDialogState(() {
                          isSending = true;
                          errorText = null;
                        });
                        try {
                          await FirebaseAuth.instance.sendPasswordResetEmail(
                            email: email,
                          );
                          if (dialogContext.mounted) {
                            Navigator.of(dialogContext).pop();
                          }
                          if (mounted) {
                            showSpotlightToast(
                              context,
                              'Check your inbox and spam folder for password reset instructions.',
                              success: true,
                            );
                          }
                        } on FirebaseAuthException catch (error) {
                          setDialogState(() {
                            isSending = false;
                            errorText = switch (error.code) {
                              'invalid-email' => 'That email address is invalid.',
                              'too-many-requests' =>
                                'Too many attempts. Wait a little and try again.',
                              'network-request-failed' =>
                                'Check your internet connection and try again.',
                              _ => 'We could not send the reset email. Please try again.',
                            };
                          });
                        } catch (_) {
                          setDialogState(() {
                            isSending = false;
                            errorText =
                                'We could not send the reset email. Please try again.';
                          });
                        }
                      },
                child: isSending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(tr('Send reset link')),
              ),
            ],
          ),
        ),
      );
    } finally {
      emailController.dispose();
    }
  }

  Widget _buildWindowsLayout() {
    const fieldFill = Color(0xFFF5F7FB);
    const fieldBorder = Color(0xFFDCE3ED);
    const ink = Color(0xFF172235);
    return WindowsAuthLayout(
      eyebrow: 'Welcome back',
      title: tr('Sign in to Duhuze'),
      subtitle: tr('Pick up where you left off and keep your network moving.'),
      footerPrompt: "New to Duhuze?",
      footerAction: 'Create account',
      onFooterTap: () => context.go(AppRoutes.register),
      form: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppTextField(
              label: tr('Email address'),
              hintText: tr('you@example.com'),
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              fillColor: fieldFill,
              textColor: ink,
              hintColor: const Color(0xFF8995A7),
              borderColor: fieldBorder,
              prefixIcon: const Icon(Icons.alternate_email_rounded,
                  color: Color(0xFF77849A)),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter your email';
                }
                if (!RegExp(r'^[^@]+@[^@]+\.[^@]+').hasMatch(value)) {
                  return 'Please enter a valid email';
                }
                return null;
              },
            ),
            const SizedBox(height: 18),
            AppTextField(
              label: tr('Password'),
              hintText: tr('Enter your password'),
              controller: _passwordController,
              obscureText: !_showPassword,
              fillColor: fieldFill,
              textColor: ink,
              hintColor: const Color(0xFF8995A7),
              borderColor: fieldBorder,
              prefixIcon: const Icon(Icons.lock_outline_rounded,
                  color: Color(0xFF77849A)),
              suffixIcon: IconButton(
                tooltip: _showPassword ? 'Hide password' : 'Show password',
                onPressed: () => setState(() => _showPassword = !_showPassword),
                icon: Icon(
                  _showPassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  color: const Color(0xFF77849A),
                ),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter your password';
                }
                if (value.trim().length < AppConstants.minPasswordLength) {
                  return 'Password must be at least ${AppConstants.minPasswordLength} characters';
                }
                return null;
              },
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _showForgotPasswordDialog,
                child: Text(tr('Forgot password?')),
              ),
            ),
            const SizedBox(height: 6),
            AppButton(
              text: 'Sign in',
              onPressed: _handleLogin,
              isLoading: _isLoading,
              height: 54,
              backgroundColor: const Color(0xFF1769AA),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                const Expanded(child: const Divider(color: fieldBorder)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Text(
                    tr('OR CONTINUE WITH'),
                    style: const TextStyle(
                      color: const Color(0xFF8995A7),
                      fontSize: 10,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const Expanded(child: const Divider(color: fieldBorder)),
              ],
            ),
            const SizedBox(height: 18),
            SizedBox(
              height: 50,
              child: OutlinedButton.icon(
                onPressed: _isLoading ? null : _handleGoogleSignIn,
                icon: Image.asset('assets/images/google.png', width: 19),
                label: Text(tr('Continue with Google')),
                style: OutlinedButton.styleFrom(
                  foregroundColor: ink,
                  side: const BorderSide(color: fieldBorder),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isWindows) return _buildWindowsLayout();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fieldFillColor = isDark
        ? const Color(0xCC1A2230).withOpacity(0.52)
        : Colors.white.withOpacity(0.22);
    final fieldBorderColor = Colors.white.withOpacity(isDark ? 0.18 : 0.14);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true,
        extendBodyBehindAppBar: true,
        body: Stack(
          children: [
            if (!isDark)
              const Positioned.fill(
                child: IgnorePointer(child: NightSkyBackground()),
              ),
            Positioned.fill(
              child: Container(
                color: isDark
                    ? Colors.black.withOpacity(0.34)
                    : Colors.black.withOpacity(0.18),
              ),
            ),
            SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 60),
                    // Header
                    Center(
                      child: Text(
                        tr('Welcome back to Duhuze'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          shadows: const [
                            Shadow(
                              color: Colors.black45,
                              blurRadius: 10,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: Text(
                        tr('Sign in to spotlight your work'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 16,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                    const SizedBox(height: 48),
                    // Form
                    Form(
                      key: _formKey,
                      child: Column(
                        children: [
                          AppTextField(
                            label: tr('Email Address'),
                            hintText: tr('Enter your email'),
                            controller: _emailController,
                            fillColor: fieldFillColor,
                            textColor: Colors.white,
                            hintColor: Colors.white60,
                            borderColor: fieldBorderColor,
                            errorStyle: const TextStyle(
                              color: Colors.redAccent,
                              backgroundColor: Colors.transparent,
                            ),
                            prefixIcon: const Icon(
                              Icons.alternate_email_rounded,
                              color: Colors.white70,
                            ),
                            keyboardType: TextInputType.emailAddress,
                            validator: (value) {
                              if (value == null || value.isEmpty) {
                                return 'Please enter your email';
                              }
                              if (!RegExp(r'^[^@]+@[^@]+\.[^@]+')
                                  .hasMatch(value)) {
                                return 'Please enter a valid email';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 20),
                          AppTextField(
                            label: tr('Password'),
                            hintText: tr('Enter your password'),
                            controller: _passwordController,
                            obscureText: !_showPassword,
                            fillColor: fieldFillColor,
                            textColor: Colors.white,
                            hintColor: Colors.white60,
                            borderColor: fieldBorderColor,
                            errorStyle: const TextStyle(
                              color: Colors.redAccent,
                              backgroundColor: Colors.transparent,
                            ),
                            prefixIcon: const Icon(
                              Icons.lock_outline_rounded,
                              color: Colors.white70,
                            ),
                            suffixIcon: IconButton(
                              tooltip: _showPassword
                                  ? 'Hide password'
                                  : 'Show password',
                              onPressed: () => setState(
                                () => _showPassword = !_showPassword,
                              ),
                              icon: Icon(
                                _showPassword
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                                color: Colors.white70,
                              ),
                            ),
                            validator: (value) {
                              if (value == null || value.isEmpty) {
                                return 'Please enter your password';
                              }
                              if (value.trim().length <
                                  AppConstants.minPasswordLength) {
                                return 'Password must be at least ${AppConstants.minPasswordLength} characters';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 24),
                          // Login Button
                          AppButton(
                            text: 'Sign In',
                            onPressed: _handleLogin,
                            isLoading: _isLoading,
                          ),
                          const SizedBox(height: 24),
                          // Forgot Password
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: () {
                                _showForgotPasswordDialog();
                              },
                              child: Text(
                                tr('Forgot Password?'),
                                style: const TextStyle(
                                  color: AppColors.primary,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 32),
                          // Divider
                          Row(
                            children: [
                              const Expanded(
                                child: const Divider(
                                  color: AppColors.lightGrey,
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                child: Text(
                                  tr('Or continue with'),
                                  style: const TextStyle(
                                    color: AppColors.grey,
                                  ),
                                ),
                              ),
                              const Expanded(
                                child: const Divider(
                                  color: AppColors.lightGrey,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 32),
                          // Social Login Buttons
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _socialButton(
                                onPressed: _handleGoogleSignIn,
                                assetPath: 'assets/images/google.png',
                                semanticLabel: tr('Continue with Google'),
                              ),
                              const SizedBox(width: 18),
                              _socialButton(
                                onPressed: _handlePhoneSignIn,
                                assetPath: 'assets/images/phone.png',
                                semanticLabel: tr('Continue with phone'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 48),
                          // Sign Up Link
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                tr("Don't have an account? "),
                                style: const TextStyle(
                                  color: AppColors.grey,
                                ),
                              ),
                              GestureDetector(
                                onTap: () {
                                  context.push(AppRoutes.register);
                                },
                                child: Text(
                                  tr('Sign Up'),
                                  style: const TextStyle(
                                    color: AppColors.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _socialButton({
    required VoidCallback onPressed,
    required String assetPath,
    required String semanticLabel,
  }) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
          width: 68,
          height: 68,
          child: Padding(
            padding: EdgeInsets.all(
              assetPath.contains('phone') ? 8 : 6,
            ),
            child: Image.asset(
              assetPath,
              fit: BoxFit.contain,
            ),
          ),
        ),
      ),
    );
  }
}
