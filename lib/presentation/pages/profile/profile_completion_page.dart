import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/colors.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/services/supabase_storage_service.dart';

class ProfileCompletionPage extends ConsumerStatefulWidget {
  const ProfileCompletionPage({super.key});

  @override
  ConsumerState<ProfileCompletionPage> createState() => _ProfileCompletionPageState();
}

class _ProfileCompletionPageState extends ConsumerState<ProfileCompletionPage> {
  final _formKey = GlobalKey<FormState>();
  final _phoneController = TextEditingController();
  final _bioController = TextEditingController();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();

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
          _nameController.text = data['name'] ?? '';
          _emailController.text = data['email'] ?? '';
          _phoneController.text = data['phone'] ?? '';
          _bioController.text = data['bio'] ?? '';
          _profileImageUrl = data['imageUrl'];
        });
      }
    }
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
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .update({
        'imageUrl': url,
        'updatedAt': FieldValue.serverTimestamp(),
      });
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
        if (user != null) {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .update({
            'userType': 'client',
            'name': _nameController.text.trim(),
            'email': _emailController.text.trim(),
            'phone': _phoneController.text.trim(),
            'bio': _bioController.text.trim(),
            'profileCompleted': true,
            'updatedAt': FieldValue.serverTimestamp(),
          });

          setState(() {
            _isLoading = false;
          });

          // Navigate to dashboard after save
          context.go(AppRoutes.dashboard);
        }
      } catch (e) {
        setState(() {
          _isLoading = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to save profile. Please try again.')),
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
                      content: Text(
                          'Failed to update password. Please re-login.'),
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        automaticallyImplyLeading: false,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Text(
                'Your Profile',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Keep your info up to date so businesses can reach you.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.grey,
                ),
              ),

              const SizedBox(height: 32),

              Center(
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 44,
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
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _isUploadingImage ? null : _pickProfileImage,
                      child: Text(
                        _isUploadingImage ? 'Uploading...' : 'Change photo',
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // Name
              AppTextField(
                controller: _nameController,
                label: 'Full Name',
                hintText: 'Enter your full name',
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
                hintText: 'Enter your email',
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
              AppTextField(
                controller: _phoneController,
                label: 'Phone Number',
                hintText: '+1 (555) 123-4567',
                keyboardType: TextInputType.phone,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter your phone number';
                  }
                  return null;
                },
              ),

              const SizedBox(height: 24),

              // Bio
              AppTextField(
                controller: _bioController,
                label: 'Bio (Optional)',
                hintText: 'Tell us a bit about yourself...',
                maxLines: 3,
                maxLength: 200,
              ),

              const SizedBox(height: 32),

              // Save Button
              AppButton(
                text: 'Save Profile',
                onPressed: _saveProfile,
                isLoading: _isLoading,
              ),

              const SizedBox(height: 12),
              TextButton(
                onPressed: _changePassword,
                child: const Text('Change Password'),
              ),

              const SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  context.go(AppRoutes.dashboard);
                },
                child: const Text('Back to dashboard'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
