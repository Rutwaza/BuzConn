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
import '../../../core/services/supabase_storage_service.dart';

class ProfileCompletionPage extends ConsumerStatefulWidget {
  const ProfileCompletionPage({super.key});

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

      if (userDoc.exists) {
        final data = userDoc.data()!;
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
    if (raw.isEmpty) return '';
    if (raw.startsWith('+')) return raw;
    return '$_dialCode$raw';
  }

  Future<void> _pickProfileImage() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;

    setState(() {
      _isUploadingImage = true;
    });
    try {
      final bytes = await picked.readAsBytes();
      final path = '${user.uid}/${DateTime.now().millisecondsSinceEpoch}.jpg';
      final url = await SupabaseStorageService.instance.uploadImage(
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to upload photo: $e')),
        );
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

        await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
          'userType': 'client',
          'name': _nameController.text.trim(),
          'email': _emailController.text.trim(),
          'phone': _normalizedPhone(),
          'bio': _bioController.text.trim(),
          'profileCompleted': true,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        if (!mounted) return;
        setState(() {
          _isLoading = false;
        });

        context.go(AppRoutes.dashboard);
      } catch (e) {
        debugPrint('Profile save failed: $e');
        if (!mounted) return;
        setState(() {
          _isLoading = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to save profile. Please try again.'),
          ),
        );
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
        title: const Text('Change password'),
        content: TextField(
          controller: controller,
          obscureText: true,
          decoration: const InputDecoration(
            hintText: 'New password',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
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
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Password updated.'),
                    ),
                  );
                }
              } on FirebaseAuthException {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content:
                          Text('Failed to update password. Please re-login.'),
                    ),
                  );
                }
              }
            },
            child: const Text('Update'),
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
        title: const Text('Edit Profile'),
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
                'About you',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 12),

              // Name
              AppTextField(
                controller: _nameController,
                label: 'Display Name',
                hintText: 'How people see you',
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter your name';
                  }
                  return null;
                },
              ),

              const SizedBox(height: 24),

              // Email
              AppTextField(
                controller: _emailController,
                label: 'Email',
                hintText: 'Email address',
                keyboardType: TextInputType.emailAddress,
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

              const SizedBox(height: 24),

              // Phone Number
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Phone',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      CountryCodePicker(
                        initialSelection: _dialCode,
                        favorite: const ['RW', 'KE', 'UG', 'TZ'],
                        showFlag: true,
                        showCountryOnly: false,
                        showOnlyCountryWhenClosed: false,
                        textStyle: TextStyle(color: pickerTextColor),
                        dialogBackgroundColor: pickerBg,
                        dialogTextStyle: TextStyle(color: pickerTextColor),
                        searchDecoration: InputDecoration(
                          hintText: 'Search country',
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
                      const SizedBox(width: 8),
                      Expanded(
                        child: AppTextField(
                          controller: _phoneController,
                          label: '',
                          hintText: 'Phone number',
                          keyboardType: TextInputType.phone,
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'Please enter your phone number';
                            }
                            return null;
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // Bio
              AppTextField(
                controller: _bioController,
                label: 'Bio',
                hintText: 'Tell people about you...',
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
                      child: const Text('Change Password'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        context.go(AppRoutes.dashboard);
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
                      child: const Text('Back'),
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
