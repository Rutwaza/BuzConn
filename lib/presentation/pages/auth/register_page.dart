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

class RegisterPage extends ConsumerStatefulWidget {
  const RegisterPage({super.key});

  @override
  ConsumerState<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends ConsumerState<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _nameController.dispose();
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
        UserCredential userCredential = await FirebaseAuth.instance
            .createUserWithEmailAndPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text.trim(),
        );

        try {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(userCredential.user!.uid)
              .set({
            'name': _nameController.text.trim(),
            'email': _emailController.text.trim(),
            'createdAt': FieldValue.serverTimestamp(),
            'userType': 'client',
            'fcmTokens': [],
            'themeMode': 'dark',
          }, SetOptions(merge: true));
        } catch (_) {}

        try {
          await userCredential.user?.sendEmailVerification();
        } catch (_) {}

        if (mounted) {
          setState(() {
            _isLoading = false;
          });
          context.go(AppRoutes.dashboard);
        }
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

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorMessage)),
        );
      } catch (_) {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
          context.go(AppRoutes.dashboard);
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
    if (snapshot.exists) return;
    await doc.set({
      'name': name ?? user.displayName ?? 'User',
      'email': email ?? user.email,
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
        context.go(AppRoutes.dashboard);
      }
    } on FirebaseAuthException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Google sign-in failed')),
      );
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Google sign-in failed')),
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
    final phoneController = TextEditingController();
    final codeController = TextEditingController();
    String? verificationId;
    bool isSending = false;
    bool isVerifying = false;
    bool codeSent = false;
    String dialCode = '+250';
    String fullPhone = '';

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            final viewInsets = MediaQuery.of(context).viewInsets.bottom;
            return Container(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 16,
                bottom: viewInsets + 20,
              ),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          codeSent ? 'Verify your number' : 'Continue with phone',
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        onPressed: isSending || isVerifying
                            ? null
                            : () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    codeSent
                        ? 'Enter the code we sent to $fullPhone'
                        : 'We’ll send a one-time code to verify your number.',
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: AppColors.grey),
                  ),
                  const SizedBox(height: 16),
                  if (!codeSent) ...[
                    Row(
                      children: [
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
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: phoneController,
                            keyboardType: TextInputType.phone,
                            decoration: const InputDecoration(
                              hintText: '7XXXXXXXX',
                              labelText: 'Phone number',
                              prefixIcon: Icon(Icons.phone),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (codeSent) ...[
                    TextField(
                      controller: codeController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        hintText: '123456',
                        labelText: 'Verification code',
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: isVerifying
                            ? null
                            : () {
                                setState(() {
                                  codeSent = false;
                                  isSending = false;
                                  isVerifying = false;
                                  verificationId = null;
                                });
                              },
                        child: const Text('Edit phone number'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: isSending || isVerifying
                          ? null
                          : () async {
                              if (!codeSent) {
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
                                      context.go(AppRoutes.dashboard);
                                    }
                                  },
                                  verificationFailed:
                                      (FirebaseAuthException e) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          e.message ??
                                              'Phone verification failed',
                                        ),
                                      ),
                                    );
                                    setState(() {
                                      isSending = false;
                                    });
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
                              } else {
                                final code = codeController.text.trim();
                                if (code.isEmpty || verificationId == null) {
                                  return;
                                }
                                setState(() {
                                  isVerifying = true;
                                });
                                try {
                                  final credential =
                                      PhoneAuthProvider.credential(
                                    verificationId: verificationId!,
                                    smsCode: code,
                                  );
                                  final userCredential =
                                      await FirebaseAuth.instance
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
                                    context.go(AppRoutes.dashboard);
                                  }
                                } on FirebaseAuthException catch (e) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        e.message ??
                                            'Invalid verification code',
                                      ),
                                    ),
                                  );
                                } finally {
                                  if (mounted) {
                                    setState(() {
                                      isVerifying = false;
                                    });
                                  }
                                }
                              }
                            },
                      child: (isSending || isVerifying)
                          ? const SizedBox(
                              height: 16,
                              width: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(codeSent ? 'Verify' : 'Send code'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
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
                      style:
                          Theme.of(context).textTheme.headlineMedium?.copyWith(
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
                    controller: _nameController,
                    label: 'Full Name',
                    hintText: 'Enter your full name',
                    fillColor: fieldFillColor,
                    textColor: Colors.white,
                    hintColor: Colors.white60,
                    borderColor: fieldBorderColor,
                    errorStyle: const TextStyle(
                      color: Colors.redAccent,
                      backgroundColor: Colors.transparent,
                    ),
                    prefixIcon: const Icon(
                      Icons.person_outline_rounded,
                      color: Colors.white70,
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please enter your name';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
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
                    hintText: 'Enter your password',
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
                      if (value.length < 6) {
                        return 'Password must be at least 6 characters';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _confirmPasswordController,
                    label: 'Confirm Password',
                    hintText: 'Confirm your password',
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
                      Icons.verified_user_outlined,
                      color: Colors.white70,
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please confirm your password';
                      }
                      if (value != _passwordController.text) {
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
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
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
