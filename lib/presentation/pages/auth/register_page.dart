import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/colors.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/spotlight_toast.dart';
import '../../../core/services/windows_google_auth_service.dart';
import 'email_verification_notice.dart';
import 'phone_sign_in_sheet.dart';
import 'windows_auth_layout.dart';

class RegisterPage extends ConsumerStatefulWidget {
  const RegisterPage({super.key});

  @override
  ConsumerState<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends ConsumerState<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isLoading = false;
  bool _showPassword = false;
  bool _showConfirmPassword = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _handleRegister() async {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _isLoading = true;
      });

      try {
        final email = _emailController.text.trim().toLowerCase();
        final existingMethods =
            await FirebaseAuth.instance.fetchSignInMethodsForEmail(email);
        if (existingMethods.isNotEmpty) {
          throw FirebaseAuthException(
            code: 'email-already-in-use',
            message: 'An account already exists with this email.',
          );
        }

        UserCredential userCredential =
            await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email,
          password: _passwordController.text.trim(),
        );

        var verificationSent = false;
        try {
          await userCredential.user?.sendEmailVerification();
          verificationSent = true;
        } catch (_) {}

        await FirebaseAuth.instance.signOut();
        if (!mounted) return;
        setState(() => _isLoading = false);
        await showEmailVerificationNotice(
          context,
          email: email,
          emailSent: verificationSent,
        );
        if (mounted) context.go(AppRoutes.login);
      } on FirebaseAuthException catch (e) {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }

        String errorMessage = 'An error occurred';
        if (e.code == 'weak-password') {
          errorMessage = 'The password provided is too weak.';
        } else if (e.code == 'email-already-in-use') {
          errorMessage = 'An account already exists with this email.';
        } else if (e.code == 'invalid-email') {
          errorMessage = 'Invalid email address.';
        }

        showSpotlightToast(context, errorMessage, success: false);
      } catch (e) {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
          showSpotlightToast(
            context,
            'Registration failed: ${e.toString()}',
            success: false,
          );
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
      'displayName': name ?? user.displayName ?? 'User',
      'email': email ?? user.email,
      'emailLower': normalizedEmail,
      'phone': phone ?? user.phoneNumber,
      'createdAt': FieldValue.serverTimestamp(),
      'userType': 'client',
      'profileCompleted': false,
      'fcmTokens': [],
      'themeMode': 'dark',
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
      if (user != null) {
        final isProfileComplete = await _ensureUserDocument(
          user,
          name: user.displayName ?? googleUser.displayName,
          email: user.email ?? googleUser.email,
        );
        if (mounted) {
          context
              .go(isProfileComplete ? AppRoutes.dashboard : AppRoutes.profile);
        }
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
    } catch (_) {
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

  Widget _buildWindowsLayout() {
    const fieldFill = Color(0xFFF5F7FB);
    const fieldBorder = Color(0xFFDCE3ED);
    const ink = Color(0xFF172235);
    return WindowsAuthLayout(
      eyebrow: 'Get started',
      title: 'Create your account',
      subtitle: 'Set up your Spotlight account and start building connections.',
      footerPrompt: 'Already have an account?',
      footerAction: 'Sign in',
      onFooterTap: () => context.go(AppRoutes.login),
      form: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppTextField(
              controller: _emailController,
              label: 'Email address',
              hintText: 'you@example.com',
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
            const SizedBox(height: 15),
            AppTextField(
              controller: _passwordController,
              label: 'Password',
              hintText: 'At least ${AppConstants.minPasswordLength} characters',
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
            const SizedBox(height: 15),
            AppTextField(
              controller: _confirmPasswordController,
              label: 'Confirm password',
              hintText: 'Re-enter your password',
              obscureText: !_showConfirmPassword,
              fillColor: fieldFill,
              textColor: ink,
              hintColor: const Color(0xFF8995A7),
              borderColor: fieldBorder,
              prefixIcon: const Icon(Icons.verified_user_outlined,
                  color: Color(0xFF77849A)),
              suffixIcon: IconButton(
                tooltip:
                    _showConfirmPassword ? 'Hide password' : 'Show password',
                onPressed: () => setState(
                  () => _showConfirmPassword = !_showConfirmPassword,
                ),
                icon: Icon(
                  _showConfirmPassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  color: const Color(0xFF77849A),
                ),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please confirm your password';
                }
                if (value.trim() != _passwordController.text.trim()) {
                  return 'Passwords do not match';
                }
                return null;
              },
            ),
            const SizedBox(height: 22),
            AppButton(
              text: 'Create account',
              onPressed: _handleRegister,
              isLoading: _isLoading,
              height: 54,
              backgroundColor: const Color(0xFF1769AA),
            ),
            const SizedBox(height: 22),
            const Row(
              children: [
                Expanded(child: Divider(color: fieldBorder)),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14),
                  child: Text(
                    'OR SIGN UP WITH',
                    style: TextStyle(
                      color: Color(0xFF8995A7),
                      fontSize: 10,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Expanded(child: Divider(color: fieldBorder)),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 50,
              child: OutlinedButton.icon(
                onPressed: _isLoading ? null : _handleGoogleSignIn,
                icon: Image.asset('assets/images/google.png', width: 19),
                label: const Text('Continue with Google'),
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
            Positioned.fill(
              child: Opacity(
                opacity: isDark ? 0.5 : 0.42,
                child: Image.asset(
                  'assets/images/chat_bg.gif',
                  fit: BoxFit.cover,
                  alignment: Alignment.center,
                  filterQuality: FilterQuality.low,
                  gaplessPlayback: true,
                ),
              ),
            ),
            Positioned.fill(
              child: Container(
                color: isDark
                    ? Colors.black.withOpacity(0.34)
                    : Colors.black.withOpacity(0.18),
              ),
            ),
            SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 80),
                    Center(
                      child: Text(
                        'Create Your Spotlight',
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          shadows: const [
                            Shadow(
                              color: Colors.black45,
                              blurRadius: 10,
                              offset: Offset(0, 2),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: Text(
                        'Join Spotlight and share your story',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              color: Colors.white70,
                            ),
                      ),
                    ),
                    const SizedBox(height: 48),
                    AppTextField(
                      controller: _emailController,
                      label: 'Email',
                      hintText: 'Enter your email',
                      keyboardType: TextInputType.emailAddress,
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
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Please enter your email';
                        }
                        if (!value.contains('@')) {
                          return 'Please enter a valid email';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    AppTextField(
                      controller: _passwordController,
                      label: 'Password',
                      hintText:
                          'At least ${AppConstants.minPasswordLength} characters',
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
                        tooltip:
                            _showPassword ? 'Hide password' : 'Show password',
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
                    const SizedBox(height: 16),
                    AppTextField(
                      controller: _confirmPasswordController,
                      label: 'Confirm Password',
                      hintText: 'Confirm your password',
                      obscureText: !_showConfirmPassword,
                      fillColor: fieldFillColor,
                      textColor: Colors.white,
                      hintColor: Colors.white60,
                      borderColor: fieldBorderColor,
                      errorStyle: const TextStyle(
                        color: Colors.redAccent,
                        backgroundColor: Colors.transparent,
                      ),
                      prefixIcon: const Icon(
                        Icons.verified_user_outlined,
                        color: Colors.white70,
                      ),
                      suffixIcon: IconButton(
                        tooltip: _showConfirmPassword
                            ? 'Hide password'
                            : 'Show password',
                        onPressed: () => setState(
                          () => _showConfirmPassword = !_showConfirmPassword,
                        ),
                        icon: Icon(
                          _showConfirmPassword
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          color: Colors.white70,
                        ),
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Please confirm your password';
                        }
                        if (value.trim() != _passwordController.text.trim()) {
                          return 'Passwords do not match';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 32),
                    AppButton(
                      text: 'Create Account',
                      onPressed: _handleRegister,
                      isLoading: _isLoading,
                    ),
                    const SizedBox(height: 24),
                    const Row(
                      children: [
                        Expanded(
                          child: Divider(color: AppColors.lightGrey),
                        ),
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            'Or continue with',
                            style: TextStyle(color: AppColors.grey),
                          ),
                        ),
                        Expanded(
                          child: Divider(color: AppColors.lightGrey),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _socialButton(
                          onPressed: _handleGoogleSignIn,
                          assetPath: 'assets/images/google.png',
                          semanticLabel: 'Continue with Google',
                        ),
                        const SizedBox(width: 18),
                        _socialButton(
                          onPressed: _handlePhoneSignIn,
                          assetPath: 'assets/images/phone.png',
                          semanticLabel: 'Continue with phone',
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'Already have an account? ',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        TextButton(
                          onPressed: () {
                            context.go(AppRoutes.login);
                          },
                          child: Text(
                            'Sign In',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
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
