import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/colors.dart';
import '../../../core/services/supabase_storage_service.dart';

class BusinessesPage extends StatefulWidget {
  const BusinessesPage({super.key});

  @override
  State<BusinessesPage> createState() => _BusinessesPageState();
}

class _BusinessesPageState extends State<BusinessesPage> {
  static const int _maxBusinesses = 2;
  File? _selectedLogo;
  bool _showInactive = false;

  Future<int> _getBusinessCount(String userId) async {
    final snapshot = await FirebaseFirestore.instance
        .collection('businesses')
        .where('ownerId', isEqualTo: userId)
        .where('isActive', isEqualTo: true)
        .get();
    return snapshot.docs.length;
  }

  void _showPremiumDialog() {
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

  Future<void> _onCreateNewBusiness() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final count = await _getBusinessCount(user.uid);
    if (count >= _maxBusinesses) {
      _showPremiumDialog();
      return;
    }

    if (mounted) {
      context.push(AppRoutes.businessSetup);
    }
  }

  void _showEditDialog(String businessId, Map<String, dynamic> data) {
    final nameController = TextEditingController(text: data['name'] ?? '');
    final descController = TextEditingController(text: data['description'] ?? '');
    final phoneController = TextEditingController(text: data['phone'] ?? '');
    final emailController = TextEditingController(text: data['email'] ?? '');
    final mapsController = TextEditingController(text: data['googleMapsLink'] ?? '');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Business'),
        content: SingleChildScrollView(
          child: Column(
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Business Name'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: descController,
                decoration: const InputDecoration(labelText: 'Description'),
                maxLines: 3,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: phoneController,
                decoration: const InputDecoration(labelText: 'Phone'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: emailController,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: mapsController,
                decoration: const InputDecoration(labelText: 'Google Maps Link'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newName = nameController.text.trim();
              final newDesc = descController.text.trim();
              final newPhone = phoneController.text.trim();
              final newEmail = emailController.text.trim();
              final newMaps = mapsController.text.trim();

              await FirebaseFirestore.instance
                  .collection('businesses')
                  .doc(businessId)
                  .update({
                'name': newName,
                'description': newDesc,
                'phone': newPhone,
                'email': newEmail,
                'googleMapsLink': newMaps,
                'updatedAt': FieldValue.serverTimestamp(),
              });

              // Propagate changes to existing posts for this business
              final postsSnapshot = await FirebaseFirestore.instance
                  .collection('posts')
                  .where('businessId', isEqualTo: businessId)
                  .get();

              final batch = FirebaseFirestore.instance.batch();
              for (final doc in postsSnapshot.docs) {
                batch.update(doc.reference, {
                  'businessName': newName,
                });
              }
              await batch.commit();

              if (mounted) {
                Navigator.of(context).pop();
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickLogo(String businessId) async {
    try {
      final picker = ImagePicker();
      final pickedFile = await picker.pickImage(source: ImageSource.gallery);
      if (pickedFile == null) return;

      setState(() {
        _selectedLogo = File(pickedFile.path);
      });

      await _uploadLogo(businessId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Logo picker failed: $e')),
        );
      }
    }
  }

  Future<void> _uploadLogo(String businessId) async {
    if (_selectedLogo == null) return;
    try {
      final bytes = await _selectedLogo!.readAsBytes();
      final path = '$businessId/logo_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final downloadUrl = await SupabaseStorageService.instance.uploadImage(
        bucket: 'profile-images',
        path: path,
        bytes: bytes,
      );

      await FirebaseFirestore.instance
          .collection('businesses')
          .doc(businessId)
          .update({
        if (downloadUrl != null) 'imageUrl': downloadUrl,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (downloadUrl != null) {
        // Propagate logo update to existing posts
        final postsSnapshot = await FirebaseFirestore.instance
            .collection('posts')
            .where('businessId', isEqualTo: businessId)
            .get();
        final batch = FirebaseFirestore.instance.batch();
        for (final doc in postsSnapshot.docs) {
          batch.update(doc.reference, {
            'businessImageUrl': downloadUrl,
          });
        }
        await batch.commit();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Logo upload failed: $e')),
        );
      }
    } finally {
      setState(() {
        _selectedLogo = null;
      });
    }
  }

  void _confirmDeleteBusiness(String businessId) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Business'),
        content: const Text(
          'This will hide the business from your profile and clients. '
          'You can re-enable it later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              await FirebaseFirestore.instance
                  .collection('businesses')
                  .doc(businessId)
                  .update({
                'isActive': false,
                'updatedAt': FieldValue.serverTimestamp(),
              });
              if (mounted) {
                Navigator.of(context).pop();
              }
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _showPremiumVerifyDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Premium Required'),
        content: const Text(
          'Business verification is available on Premium. Upgrade to verify.',
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

  void _restoreBusiness(String businessId) async {
    await FirebaseFirestore.instance.collection('businesses').doc(businessId).update({
      'isActive': true,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Widget _clientEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.storefront, size: 64, color: AppColors.grey),
          const SizedBox(height: 12),
          const Text('You have no businesses yet'),
          const SizedBox(height: 8),
          const Text('Set up your first business profile'),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: _onCreateNewBusiness,
            child: const Text('Create your business profile'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Businesses'),
        actions: [
          IconButton(
            onPressed: _onCreateNewBusiness,
            icon: const Icon(Icons.add),
            tooltip: 'Create Business',
          ),
          IconButton(
            onPressed: () {
              setState(() {
                _showInactive = !_showInactive;
              });
            },
            icon: Icon(_showInactive ? Icons.visibility_off : Icons.visibility),
            tooltip: _showInactive ? 'Hide inactive' : 'Show inactive',
          ),
        ],
      ),
      body: user == null
          ? const Center(child: Text('Please sign in to manage businesses.'))
          : StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('businesses')
                  .where('ownerId', isEqualTo: user.uid)
                  .where('isActive', isEqualTo: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(child: Text('Error: ${snapshot.error}'));
                }
                final activeDocs = snapshot.data?.docs ?? [];
                if (activeDocs.isEmpty) {
                  return _clientEmptyState();
                }
                if (activeDocs.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.business, size: 64, color: AppColors.grey),
                        const SizedBox(height: 12),
                        const Text('No businesses yet'),
                        const SizedBox(height: 12),
                        ElevatedButton(
                          onPressed: _onCreateNewBusiness,
                          child: const Text('Create your first business'),
                        ),
                      ],
                    ),
                  );
                }

                return ListView(
                  children: [
                    ...activeDocs.map((doc) {
                      final data = doc.data() as Map<String, dynamic>;
                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: ListTile(
                        onTap: () => context.push(
                          AppRoutes.businessProfilePath(doc.id),
                        ),
                        leading: CircleAvatar(
                          backgroundColor: AppColors.primary,
                          backgroundImage: (data['imageUrl'] != null &&
                                  (data['imageUrl'] as String).isNotEmpty)
                                ? NetworkImage(data['imageUrl'])
                                : null,
                            child: (data['imageUrl'] == null ||
                                    (data['imageUrl'] as String).isEmpty)
                                ? Text(
                                    (data['name'] ?? '?')
                                        .toString()
                                        .substring(0, 1)
                                        .toUpperCase(),
                                    style: const TextStyle(color: Colors.white),
                                  )
                                : null,
                          ),
                        title: Text(data['name'] ?? 'Unnamed Business'),
                        subtitle: Text(data['category'] ?? 'Category'),
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'edit') {
                              _showEditDialog(doc.id, data);
                            } else if (value == 'logo') {
                              _pickLogo(doc.id);
                            } else if (value == 'delete') {
                              _confirmDeleteBusiness(doc.id);
                            } else if (value == 'verify') {
                              _showPremiumVerifyDialog();
                            }
                          },
                          itemBuilder: (context) => const [
                            PopupMenuItem(
                              value: 'edit',
                              child: Text('Edit'),
                            ),
                            PopupMenuItem(
                              value: 'logo',
                              child: Text('Update Logo'),
                            ),
                            PopupMenuItem(
                              value: 'verify',
                              child: Text('Verify (Premium)'),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text('Delete'),
                            ),
                          ],
                        ),
                        ),
                      );
                    }),
                    if (_showInactive)
                      StreamBuilder<QuerySnapshot>(
                        stream: FirebaseFirestore.instance
                            .collection('businesses')
                            .where('ownerId', isEqualTo: user.uid)
                            .where('isActive', isEqualTo: false)
                            .snapshots(),
                        builder: (context, inactiveSnapshot) {
                          if (inactiveSnapshot.connectionState == ConnectionState.waiting) {
                            return const Padding(
                              padding: EdgeInsets.all(16),
                              child: LinearProgressIndicator(),
                            );
                          }
                          if (inactiveSnapshot.hasError) {
                            return Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text('Error: ${inactiveSnapshot.error}'),
                            );
                          }
                          final inactiveDocs = inactiveSnapshot.data?.docs ?? [];
                          if (inactiveDocs.isEmpty) {
                            return const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('No inactive businesses.'),
                            );
                          }
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Padding(
                                padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                                child: Text(
                                  'Inactive Businesses',
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                              ),
                              ...inactiveDocs.map((doc) {
                                final data = doc.data() as Map<String, dynamic>;
                                return Card(
                                  margin:
                                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                  child: ListTile(
                                    leading: const Icon(Icons.business_outlined),
                                    title: Text(data['name'] ?? 'Unnamed Business'),
                                    subtitle: const Text('Inactive'),
                                    trailing: TextButton(
                                      onPressed: () => _restoreBusiness(doc.id),
                                      child: const Text('Restore'),
                                    ),
                                  ),
                                );
                              }),
                            ],
                          );
                        },
                      ),
                  ],
                );
              },
            ),
      bottomNavigationBar: FutureBuilder<int>(
        future: user == null ? Future.value(0) : _getBusinessCount(user.uid),
        builder: (context, snapshot) {
          final count = snapshot.data ?? 0;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: AppColors.lightGrey,
            child: Row(
              children: [
                Expanded(
                  child: Text('Businesses: $count / $_maxBusinesses'),
                ),
                TextButton(
                  onPressed: _onCreateNewBusiness,
                  child: const Text('Add New'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
