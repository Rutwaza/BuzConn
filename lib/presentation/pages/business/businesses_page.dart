import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/colors.dart';
import '../../../core/services/r2_storage_service.dart';

class BusinessesPage extends StatefulWidget {
  const BusinessesPage({super.key});

  @override
  State<BusinessesPage> createState() => _BusinessesPageState();
}

class _BusinessesPageState extends State<BusinessesPage> {
  static const int _maxBusinesses = 2;
  File? _selectedLogo;
  bool _showInactive = false;

  void _showPremiumStyledDialog({
    required String title,
    required String message,
  }) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF141821) : Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: isDark ? Colors.white10 : Colors.black12,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [
                        AppColors.primary.withOpacity(0.95),
                        AppColors.primary.withOpacity(0.55),
                      ],
                    ),
                  ),
                  child: const Icon(
                    Icons.stars_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  title,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: AppColors.grey),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withOpacity(0.06)
                        : Colors.black.withOpacity(0.04),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.check_circle,
                          color: AppColors.primary, size: 18),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Unlimited pages • Priority review • Featured boost',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: OutlinedButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('Not now'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.of(context).pop();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Premium upgrade coming soon!'),
                            ),
                          );
                        },
                        style: ElevatedButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('Go Premium'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<int> _getBusinessCount(String userId) async {
    final snapshot = await FirebaseFirestore.instance
        .collection('businesses')
        .where('ownerId', isEqualTo: userId)
        .where('isActive', isEqualTo: true)
        .get();
    return snapshot.docs.length;
  }

  void _showPremiumDialog() {
    _showPremiumStyledDialog(
      title: 'Go Premium',
      message:
          'Free accounts can create up to 2 pages. Upgrade to add more.',
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
      final downloadUrl = await R2StorageService.instance.uploadImage(
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
        title: const Text('Delete Page'),
        content: const Text(
          'This will hide the page from your profile and followers. '
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
    _showPremiumStyledDialog(
      title: 'Premium Required',
      message: 'Page verification is available on Premium. Upgrade to verify.',
    );
  }

  void _restoreBusiness(String businessId) async {
    await FirebaseFirestore.instance.collection('businesses').doc(businessId).update({
      'isActive': true,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Widget _clientEmptyState() {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.storefront, size: 64, color: AppColors.grey),
          const SizedBox(height: 12),
          const Text('You have no pages yet'),
          const SizedBox(height: 8),
          const Text('Set up your first creator page'),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: _onCreateNewBusiness,
            style: ElevatedButton.styleFrom(
              backgroundColor: scheme.primary,
              foregroundColor: scheme.onPrimary,
            ),
            child: const Text('Create your page'),
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
        title: const Text('My Pages'),
        actions: [
          IconButton(
            onPressed: _onCreateNewBusiness,
            icon: const Icon(Icons.add),
            tooltip: 'Create Page',
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
          ? const Center(child: Text('Please sign in to manage pages.'))
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
                        const Text('No pages yet'),
                        const SizedBox(height: 12),
                        ElevatedButton(
                          onPressed: _onCreateNewBusiness,
                          child: const Text('Create your first page'),
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
                        title: Text(data['name'] ?? 'Unnamed Page'),
                        subtitle: Text(data['category'] ?? 'Category'),
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'edit') {
                              context.push(
                                '${AppRoutes.businessSetup}?businessId=${doc.id}',
                              );
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
                              child: Text('No inactive pages.'),
                            );
                          }
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Padding(
                                padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                                child: Text(
                                  'Inactive Pages',
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
                                    title: Text(data['name'] ?? 'Unnamed Page'),
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
          final scheme = Theme.of(context).colorScheme;
          final isDark = Theme.of(context).brightness == Brightness.dark;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: isDark ? scheme.surface : AppColors.lightGrey,
              border: Border(
                top: BorderSide(
                  color: isDark ? Colors.white12 : Colors.black12,
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Pages: $count / $_maxBusinesses',
                    style: TextStyle(
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _onCreateNewBusiness,
                  style: TextButton.styleFrom(
                    foregroundColor: scheme.primary,
                  ),
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
