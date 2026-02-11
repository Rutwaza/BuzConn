import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'dart:typed_data';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/colors.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/services/supabase_storage_service.dart';

class BusinessSetupPage extends ConsumerStatefulWidget {
  const BusinessSetupPage({super.key});

  @override
  ConsumerState<BusinessSetupPage> createState() => _BusinessSetupPageState();
}

class _BusinessSetupPageState extends ConsumerState<BusinessSetupPage> {
  final _formKey = GlobalKey<FormState>();
  final _businessNameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _addressController = TextEditingController();
  final _googleMapsLinkController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();

  String _selectedCategory = 'Other';
  bool _isLoading = false;
  File? _selectedImage;
  Uint8List? _selectedImageBytes;

  final List<String> _categories = [
    'Restaurant',
    'Retail',
    'Healthcare',
    'Education',
    'Technology',
    'Construction',
    'Automotive',
    'Beauty & Spa',
    'Fitness',
    'Consulting',
    'Other',
  ];

  @override
  void initState() {
    super.initState();
    _loadCurrentUser();
  }

  Future<void> _loadCurrentUser() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      _emailController.text = user.email ?? '';
    }
  }

  Future<void> _createBusiness() async {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _isLoading = true;
      });

      try {
        final user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          final existingBusinesses = await FirebaseFirestore.instance
              .collection('businesses')
              .where('ownerId', isEqualTo: user.uid)
              .get();
          if (existingBusinesses.docs.length >= 2) {
            setState(() {
              _isLoading = false;
            });
            if (mounted) {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Go Premium'),
                  content: const Text(
                    'Free accounts can create up to 2 businesses. '
                    'Upgrade to Premium to add more.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Not now'),
                    ),
                    ElevatedButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Premium upgrade coming soon!')),
                        );
                      },
                      child: const Text('Go Premium'),
                    ),
                  ],
                ),
              );
            }
            return;
          }

          // Create business document
          final businessRef = await FirebaseFirestore.instance
              .collection('businesses')
              .add({
            'ownerId': user.uid,
            'name': _businessNameController.text.trim(),
            'description': _descriptionController.text.trim(),
            'category': _selectedCategory,
            'phone': _phoneController.text.trim(),
            'email': _emailController.text.trim(),
            'isVerified': false,
            'isActive': true,
            'rating': 0.0,
            'reviewCount': 0,
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          });

          // Upload image if selected
          String? imageUrl;
          if (_selectedImage != null) {
            imageUrl = await _uploadImage(_selectedImage!, businessRef.id);
          }

          // Update business document with image URL
          await businessRef.update({
            'googleMapsLink': _googleMapsLinkController.text.trim(),
            if (imageUrl != null) 'imageUrl': imageUrl,
          });

          // Update user document to mark as business owner
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .update({
            'businessId': businessRef.id,
            'userType': 'business',
            'updatedAt': FieldValue.serverTimestamp(),
          });

          setState(() {
            _isLoading = false;
          });

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Business created successfully!'),
                backgroundColor: Colors.green,
              ),
            );

            // Navigate to dashboard
            context.go(AppRoutes.dashboard);
          }
        }
      } catch (e) {
        setState(() {
          _isLoading = false;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to create business. Please try again.')),
          );
        }
      }
    }
  }

  @override
  void dispose() {
    _businessNameController.dispose();
    _descriptionController.dispose();
    _addressController.dispose();
    _googleMapsLinkController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final picker = ImagePicker();
      final pickedFile = await picker.pickImage(source: ImageSource.gallery);

      if (pickedFile != null) {
        final bytes = await pickedFile.readAsBytes();
        setState(() {
          _selectedImage = File(pickedFile.path);
          _selectedImageBytes = bytes;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Image picker failed: $e')),
        );
      }
    }
  }

  Future<String?> _uploadImage(File imageFile, String businessId) async {
    try {
      final bytes = await imageFile.readAsBytes();
      final path = '$businessId/logo_${DateTime.now().millisecondsSinceEpoch}.jpg';
      return await SupabaseStorageService.instance.uploadImage(
        bucket: 'profile-images',
        path: path,
        bytes: bytes,
      );
    } catch (e) {
      debugPrint('Error uploading image: $e');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Set Up Your Business'),
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
                'Create your business profile',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Fill in the details below to get started.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.grey,
                ),
              ),

              const SizedBox(height: 32),

              // Business Name
              AppTextField(
                controller: _businessNameController,
                label: 'Business Name',
                hintText: 'Enter your business name',
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter your business name';
                  }
                  return null;
                },
              ),

              const SizedBox(height: 24),

              // Category
              Text(
                'Business Category',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _selectedCategory,
                decoration: InputDecoration(
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
                items: _categories.map((category) {
                  return DropdownMenuItem(
                    value: category,
                    child: Text(category),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedCategory = value!;
                  });
                },
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please select a category';
                  }
                  return null;
                },
              ),

              const SizedBox(height: 24),

              // Description
              AppTextField(
                controller: _descriptionController,
                label: 'Business Description',
                hintText: 'Describe your business and services...',
                maxLines: 3,
                maxLength: 500,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter a business description';
                  }
                  return null;
                },
              ),

              const SizedBox(height: 24),

              // Google Maps Link
              AppTextField(
                controller: _googleMapsLinkController,
                label: 'Google Maps Link',
                hintText: 'https://maps.google.com/...',
                keyboardType: TextInputType.url,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter your Google Maps link';
                  }
                  // Basic URL validation
                  final v = value.toLowerCase();
                  if (!v.contains('maps.google.com') &&
                      !v.contains('goo.gl/maps') &&
                      !v.contains('maps.app.goo.gl')) {
                    return 'Please enter a valid Google Maps link';
                  }
                  return null;
                },
              ),

              const SizedBox(height: 24),

              // Business Image
              Text(
                'Business Logo/Image',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                height: 200,
                width: double.infinity,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _selectedImageBytes != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(
                          _selectedImageBytes!,
                          fit: BoxFit.cover,
                        ),
                      )
                    : const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.image,
                            size: 48,
                            color: Colors.grey,
                          ),
                          SizedBox(height: 8),
                          Text(
                            'No image selected',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                onPressed: _pickImage,
                icon: const Icon(Icons.photo_library),
                label: const Text('Select Image'),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                ),
              ),

              const SizedBox(height: 24),

              // Phone
              AppTextField(
                controller: _phoneController,
                label: 'Business Phone',
                hintText: '+1 (555) 123-4567',
                keyboardType: TextInputType.phone,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter your business phone number';
                  }
                  return null;
                },
              ),

              const SizedBox(height: 24),

              // Email
              AppTextField(
                controller: _emailController,
                label: 'Business Email',
                hintText: 'business@example.com',
                keyboardType: TextInputType.emailAddress,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter your business email';
                  }
                  if (!RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(value)) {
                    return 'Please enter a valid email address';
                  }
                  return null;
                },
              ),

              const SizedBox(height: 32),

              // Info Card
              Card(
                color: AppColors.primary.withValues(alpha: 0.1),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.info_outline,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Your business profile will be reviewed before it becomes visible to clients. This usually takes 24-48 hours.',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 32),

              // Create Business Button
              AppButton(
                text: 'Create Business Profile',
                onPressed: _createBusiness,
                isLoading: _isLoading,
              ),

              const SizedBox(height: 16),

              // Skip for now
              TextButton(
                onPressed: () {
                  context.go(AppRoutes.dashboard);
                },
                child: const Text('Skip for now'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
