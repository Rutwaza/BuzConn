import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:country_code_picker/country_code_picker.dart';
import 'package:flutter/services.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/colors.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/spotlight_toast.dart';

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

      try {
        // Firebase authentication
        final credential = await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text.trim(),
        );

        final user = credential.user;
        if (user != null) {
          try {
            await _ensureUserDocument(user);
          } catch (_) {
            // Do not block login if user doc creation fails.
          }
        }

        if (!mounted) return;
        setState(() {
          _isLoading = false;
        });

        // Navigate to feed after successful login
        context.go(AppRoutes.feed);
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

        if (FirebaseAuth.instance.currentUser != null && mounted) {
          // Auth succeeded but an exception was raised after; proceed.
          context.go(AppRoutes.feed);
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

        if (FirebaseAuth.instance.currentUser != null && mounted) {
          context.go(AppRoutes.feed);
          return;
        }
        if (mounted) {
          showSpotlightToast(context, 'Unexpected error: $e', success: false);
        }
      }
    }
  }

  Future<void> _ensureUserDocument(
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
      return;
    }
    await doc.set({
      'name': name ?? user.displayName ?? 'User',
      'email': email ?? user.email,
      'emailLower': normalizedEmail,
      'phone': phone ?? user.phoneNumber,
      'createdAt': FieldValue.serverTimestamp(),
      'userType': 'client',
      'fcmTokens': [],
      'themeMode': 'dark',
    });
  }

  Future<void> _handleGoogleSignIn() async {
    setState(() {
      _isLoading = true;
    });
    try {
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
        await _ensureUserDocument(
          user,
          name: user.displayName ?? googleUser.displayName,
          email: user.email ?? googleUser.email,
        );
      }
      if (mounted) {
        context.go(AppRoutes.feed);
      }
    } on FirebaseAuthException catch (e) {
      showSpotlightToast(
        context,
        e.message ?? 'Google sign-in failed',
        success: false,
      );
    } catch (_) {
      showSpotlightToast(context, 'Google sign-in failed', success: false);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _handlePhoneSignIn() async {
    final phoneController = TextEditingController();
    final codeController = TextEditingController();
    String? verificationId;
    bool isSending = false;
    bool isVerifying = false;
    bool codeSent = false;
    String dialCode = '+250';
    String fullPhone = '';

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Continue with phone'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      hintText: '7XXXXXXXX',
                      labelText: 'Phone number',
                      prefixIcon: Icon(Icons.phone),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('Country'),
                      const SizedBox(width: 12),
                      CountryCodePicker(
                        initialSelection: 'RW',
                        favorite: const ['RW', 'KE', 'UG', 'TZ'],
                        showFlag: true,
                        showCountryOnly: false,
                        showOnlyCountryWhenClosed: false,
                        onChanged: (code) {
                          dialCode = code.dialCode ?? '+250';
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (codeSent)
                    TextField(
                      controller: codeController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        hintText: '123456',
                        labelText: 'Verification code',
                      ),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: isSending || isVerifying
                      ? null
                      : () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                if (!codeSent)
                  ElevatedButton(
                    onPressed: isSending
                        ? null
                        : () async {
                            final phone = phoneController.text.trim();
                            if (phone.isEmpty) return;
                            fullPhone = '$dialCode$phone';
                            setState(() {
                              isSending = true;
                            });
                            await FirebaseAuth.instance.verifyPhoneNumber(
                              phoneNumber: fullPhone,
                              verificationCompleted:
                                  (PhoneAuthCredential credential) async {
                                final userCredential = await FirebaseAuth
                                    .instance
                                    .signInWithCredential(credential);
                                final user = userCredential.user;
                                if (user != null) {
                                  await _ensureUserDocument(
                                    user,
                                    phone: user.phoneNumber ?? fullPhone,
                                  );
                                }
                                if (mounted) {
                                  Navigator.pop(context);
                                  context.go(AppRoutes.feed);
                                }
                              },
                              verificationFailed: (FirebaseAuthException e) {
                                showSpotlightToast(
                                  context,
                                  e.message ?? 'Phone verification failed',
                                  success: false,
                                );
                              },
                              codeSent: (String id, int? resendToken) {
                                verificationId = id;
                                setState(() {
                                  codeSent = true;
                                  isSending = false;
                                });
                              },
                              codeAutoRetrievalTimeout: (String id) {
                                verificationId = id;
                              },
                            );
                          },
                    child: isSending
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Send code'),
                  ),
                if (codeSent)
                  ElevatedButton(
                    onPressed: isVerifying
                        ? null
                        : () async {
                            final code = codeController.text.trim();
                            if (code.isEmpty || verificationId == null) return;
                            setState(() {
                              isVerifying = true;
                            });
                            try {
                            final credential = PhoneAuthProvider.credential(
                              verificationId: verificationId!,
                              smsCode: code,
                            );
                            final userCredential = await FirebaseAuth.instance
                                .signInWithCredential(credential);
                            final user = userCredential.user;
                            if (user != null) {
                              await _ensureUserDocument(
                                user,
                                phone: user.phoneNumber ?? fullPhone,
                              );
                            }
                              if (mounted) {
                                Navigator.pop(context);
                                context.go(AppRoutes.feed);
                              }
                            } on FirebaseAuthException catch (e) {
                              showSpotlightToast(
                                context,
                                e.message ?? 'Invalid verification code',
                                success: false,
                              );
                            } finally {
                              if (mounted) {
                                setState(() {
                                  isVerifying = false;
                                });
                              }
                            }
                          },
                    child: isVerifying
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Verify'),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showForgotPasswordDialog() async {
    final emailController = TextEditingController(
      text: _emailController.text.trim(),
    );
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset password'),
        content: TextField(
          controller: emailController,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            hintText: 'Enter your email',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final email = emailController.text.trim();
              if (email.isEmpty) return;
              try {
                await FirebaseAuth.instance.sendPasswordResetEmail(
                  email: email,
                );
                if (mounted) {
                  Navigator.pop(context);
                  showSpotlightToast(
                    context,
                    'Password reset email sent.',
                    success: true,
                  );
                }
              } catch (_) {
                if (mounted) {
                  showSpotlightToast(
                    context,
                    'Failed to send reset email.',
                    success: false,
                  );
                }
              }
            },
            child: const Text('Send'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 60),
                  // Header
                  const Center(
                    child: Text(
                      'Welcome Back to Spotlight',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        shadows: [
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
                  const Center(
                    child: Text(
                      'Sign in to spotlight your work',
                      textAlign: TextAlign.center,
                      style: TextStyle(
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
                          label: 'Email Address',
                          hintText: 'Enter your email',
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
                          label: 'Password',
                          hintText: 'Enter your password',
                          controller: _passwordController,
                          obscureText: true,
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
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'Please enter your password';
                            }
                            if (value.length < AppConstants.minPasswordLength) {
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
                            child: const Text(
                              'Forgot Password?',
                              style: TextStyle(
                                color: AppColors.primary,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 32),
                        // Divider
                        const Row(
                          children: [
                            Expanded(
                              child: Divider(
                                color: AppColors.lightGrey,
                              ),
                            ),
                            Padding(
                              padding: EdgeInsets.symmetric(horizontal: 16),
                              child: Text(
                                'Or continue with',
                                style: TextStyle(
                                  color: AppColors.grey,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Divider(
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
                        const SizedBox(height: 48),
                        // Sign Up Link
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text(
                              "Don't have an account? ",
                              style: TextStyle(
                                color: AppColors.grey,
                              ),
                            ),
                            GestureDetector(
                              onTap: () {
                                context.push(AppRoutes.register);
                              },
                              child: const Text(
                                'Sign Up',
                                style: TextStyle(
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
