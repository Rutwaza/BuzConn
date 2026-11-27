import 'package:businessfinder/core/widgets/emoji_picker.dart';
import 'package:businessfinder/core/services/media_picker.dart';
import 'dart:io';
import 'package:businessfinder/core/i18n/tr.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:country_code_picker/country_code_picker.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/colors.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/services/r2_storage_service.dart';
import 'package:businessfinder/core/widgets/app_toast.dart';

class ProfileCompletionPage extends ConsumerStatefulWidget {
  const ProfileCompletionPage({super.key, this.editing = false});

  /// Opened from "Edit profile": stay on the page and go back when done.
  final bool editing;

  @override
  ConsumerState<ProfileCompletionPage> createState() =>
      _ProfileCompletionPageState();
}

class _ProfileCompletionPageState extends ConsumerState<ProfileCompletionPage> {
  final _formKey = GlobalKey<FormState>();
  final _phoneController = TextEditingController();
  final _bioController = TextEditingController();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  String _dialCode = '+250';

  bool _isLoading = false;
  bool _isUploadingImage = false;
  String? _profileImageUrl;

  @override
  void initState() {
    super.initState();
    _loadCurrentUserData();
  }

  Future<void> _loadCurrentUserData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      if (!mounted) return;

      if (userDoc.exists) {
        final data = userDoc.data()!;
        if (data['profileCompleted'] == true && !widget.editing) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) context.go(AppRoutes.dashboard);
          });
          return;
        }
        setState(() {
          _nameController.text =
              (data['name'] ?? user.displayName ?? '').toString();
          _emailController.text =
              (data['email'] ?? user.email ?? '').toString();
          final rawPhone = (data['phone'] ?? user.phoneNumber ?? '').toString();
          if (rawPhone.startsWith('+')) {
            final match = RegExp(r'^\+\d{1,4}').firstMatch(rawPhone);
            if (match != null) {
              _dialCode = match.group(0)!;
              _phoneController.text =
                  rawPhone.substring(_dialCode.length).trim();
            } else {
              _phoneController.text = rawPhone;
            }
          } else {
            _phoneController.text = rawPhone;
          }
          _bioController.text = data['bio'] ?? '';
          _profileImageUrl = data['imageUrl'];
        });
      } else {
        setState(() {
          _nameController.text = user.displayName ?? '';
          _emailController.text = user.email ?? '';
          final rawPhone = user.phoneNumber ?? '';
          if (rawPhone.startsWith('+')) {
            final match = RegExp(r'^\+\d{1,4}').firstMatch(rawPhone);
            if (match != null) {
              _dialCode = match.group(0)!;
              _phoneController.text =
                  rawPhone.substring(_dialCode.length).trim();
            } else {
              _phoneController.text = rawPhone;
            }
          } else {
            _phoneController.text = rawPhone;
          }
        });
      }
    }
  }

  String _normalizedPhone() {
    final raw = _phoneController.text.trim();
    if (raw.isEmpty) {
      return FirebaseAuth.instance.currentUser?.phoneNumber ?? '';
    }
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    final dialDigits = _dialCode.replaceAll(RegExp(r'\D'), '');
    if (raw.startsWith('+') ||
        (digits.startsWith(dialDigits) &&
            digits.length > dialDigits.length + 6)) {
      return '+$digits';
    }
    final nationalNumber =
        digits.startsWith('0') ? digits.substring(1) : digits;
    return '$_dialCode$nationalNumber';
  }

  Future<void> _pickProfileImage() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final picked = await MediaPicker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;

    setState(() {
      _isUploadingImage = true;
    });
    try {
      final bytes = await picked.readAsBytes();
      final path = '${user.uid}/${DateTime.now().millisecondsSinceEpoch}.jpg';
      final url = await R2StorageService.instance.uploadImage(
        bucket: 'profile-images',
        path: path,
        bytes: bytes,
      );
      if (url == null) throw Exception('Upload failed');
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'imageUrl': url,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      if (mounted) {
        setState(() {
          _profileImageUrl = url;
        });
      }
    } catch (e) {
      if (mounted) {
        showToast(context, 'Failed to upload photo: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingImage = false;
        });
      }
    }
  }

  Future<void> _saveProfile() async {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _isLoading = true;
      });

      try {
        final user = FirebaseAuth.instance.currentUser;
        if (user == null) {
          throw FirebaseAuthException(code: 'no-current-user');
        }

        final email = _emailController.text.trim();

        await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
          'userType': 'client',
          'name': _nameController.text.trim(),
          'displayName': _nameController.text.trim(),
          if (email.isNotEmpty) 'email': email,
          if (email.isNotEmpty) 'emailLower': email.toLowerCase(),
          'phone': _normalizedPhone(),
          'bio': _bioController.text.trim(),
          'profileCompleted': true,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        if (!Platform.isWindows) {
          try {
            await user.updateDisplayName(_nameController.text.trim());
          } catch (_) {
            // The Firestore profile remains the source of truth for the app UI.
          }
        }

        if (!mounted) return;
        setState(() {
          _isLoading = false;
        });

        if (widget.editing && context.canPop()) {
          context.pop();
        } else {
          context.go(AppRoutes.dashboard);
        }
      } catch (e) {
        debugPrint('Profile save failed: $e');
        if (!mounted) return;
        setState(() {
          _isLoading = false;
        });

        showToast(context, 'Failed to save profile: $e');
      }
    }
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _bioController.dispose();
    _nameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _changePassword() async {
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Change password')),
        content: TextField(
          controller: controller,
          obscureText: true,
          decoration: InputDecoration(
            hintText: tr('New password'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Cancel')),
          ),
          ElevatedButton(
            onPressed: () async {
              final newPass = controller.text.trim();
              if (newPass.length < AppConstants.minPasswordLength) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Password must be at least ${AppConstants.minPasswordLength} characters.',
                    ),
                  ),
                );
                return;
              }
              try {
                await FirebaseAuth.instance.currentUser
                    ?.updatePassword(newPass);
                if (mounted) {
                  Navigator.pop(context);
                  showToast(context, tr('Password updated.'));
                }
              } on FirebaseAuthException {
                if (mounted) {
                  showToast(context, tr('Failed to update password. Please re-login.'));
                }
              }
            },
            child: Text(tr('Update')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pickerTextColor = isDark ? Colors.white : Colors.black87;
    final pickerBg = isDark ? const Color(0xFF0F131B) : Colors.white;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Edit Profile')),
        automaticallyImplyLeading: false,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF151A24) : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isDark ? Colors.white10 : Colors.black12,
                  ),
                ),
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 50,
                      backgroundColor: AppColors.primary,
                      backgroundImage: _profileImageUrl != null
                          ? NetworkImage(_profileImageUrl!)
                          : null,
                      child: _profileImageUrl == null
                          ? Text(
                              _nameController.text.isNotEmpty
                                  ? _nameController.text[0].toUpperCase()
                                  : '?',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                              ),
                            )
                          : null,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _nameController.text.isEmpty
                          ? 'Your Name'
                          : _nameController.text,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                    if (_emailController.text.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        _emailController.text,
                        style: const TextStyle(
                          color: AppColors.grey,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _isUploadingImage ? null : _pickProfileImage,
                      icon: const Icon(Icons.photo_camera),
                      label: Text(
                        _isUploadingImage ? 'Uploading...' : 'Change photo',
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primary,
                        side: const BorderSide(color: AppColors.primary),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),
              Text(
                tr('About you'),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 12),

              AppTextField(
                controller: _nameController,
                label: tr('Display Name'),
                hintText: tr('How people see you'),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter your name';
                  }
                  return null;
                },
              ),

              const SizedBox(height: 24),

              // Email
              AppTextField(
                controller: _emailController,
                label: tr('Email (optional)'),
                hintText: tr('Email address, if you want to add one'),
                keyboardType: TextInputType.emailAddress,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) return null;
                  if (!RegExp(r'^[^@]+@[^@]+\.[^@]+$').hasMatch(value.trim())) {
                    return 'Please enter a valid email';
                  }
                  return null;
                },
              ),

              const SizedBox(height: 24),

              // Phone Number
              AppTextField(
                controller: _phoneController,
                label: tr('Phone (optional)'),
                hintText: tr('Phone number'),
                keyboardType: TextInputType.phone,
                prefixIcon: CountryCodePicker(
                  initialSelection: _dialCode,
                  favorite: const ['RW', 'KE', 'UG', 'TZ'],
                  showFlag: true,
                  showCountryOnly: false,
                  showOnlyCountryWhenClosed: false,
                  textStyle: TextStyle(color: pickerTextColor),
                  dialogBackgroundColor: pickerBg,
                  dialogTextStyle: TextStyle(color: pickerTextColor),
                  searchDecoration: InputDecoration(
                    hintText: tr('Search country'),
                    hintStyle: TextStyle(
                      color: pickerTextColor.withOpacity(0.6),
                    ),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(
                        color: pickerTextColor.withOpacity(0.3),
                      ),
                    ),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(
                        color: pickerTextColor.withOpacity(0.6),
                      ),
                    ),
                  ),
                  onChanged: (code) {
                    setState(() {
                      _dialCode = code.dialCode ?? _dialCode;
                    });
                  },
                ),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 112,
                  maxWidth: 132,
                  minHeight: 56,
                  maxHeight: 56,
                ),
              ),

              const SizedBox(height: 24),

              // Bio
              AppTextField(
                controller: _bioController,
                suffixIcon: EmojiButton(controller: _bioController),
                label: tr('Bio'),
                hintText: tr('Tell people about you...'),
                maxLines: 3,
                maxLength: 200,
              ),

              const SizedBox(height: 32),

              // Save Button
              AppButton(
                text: 'Save Changes',
                onPressed: _saveProfile,
                isLoading: _isLoading,
              ),

              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _changePassword,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primary,
                        side: const BorderSide(color: AppColors.primary),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(tr('Change Password')),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        if (widget.editing && context.canPop()) {
                          context.pop();
                        } else {
                          context.go(AppRoutes.dashboard);
                        }
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.grey,
                        side: BorderSide(
                          color: isDark ? Colors.white24 : Colors.black12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(tr('Back')),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
