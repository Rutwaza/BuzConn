import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/colors.dart';
import '../../../core/services/theme_mode_service.dart';

class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});

  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  User? _currentUser;
  StreamSubscription<User?>? _authSub;

  @override
  void initState() {
    super.initState();
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (!mounted) return;
      if (user == null) {
        context.go(AppRoutes.login);
        return;
      }
      _currentUser = user;
    });
    _loadUserData();
  }

  Future<void> _loadUserData() async {
    _currentUser = FirebaseAuth.instance.currentUser;
    if (_currentUser != null) {
      DocumentSnapshot userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUser!.uid)
          .get();

      if (userDoc.exists) {
        final userData = userDoc.data() as Map<String, dynamic>;
        setState(() {
        });
        await ThemeModeService.instance.loadFromUser();

        // Check if profile is completed
        final profileCompleted = userData['profileCompleted'] ?? false;
        if (!profileCompleted && mounted) {
          // Redirect to profile completion
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) {
              context.go(AppRoutes.profile);
            }
          });
        }
      }
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  Future<void> _signOut() async {
    await FirebaseAuth.instance.signOut();
    if (mounted) {
      context.go(AppRoutes.login);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Spotlight'),
        leading: null,
        actions: [
          IconButton(
            icon: Icon(
              ThemeModeService.instance.mode.value == AppThemeMode.dark
                  ? Icons.light_mode
                  : ThemeModeService.instance.mode.value == AppThemeMode.cyber
                      ? Icons.bolt
                      : Icons.dark_mode,
            ),
            onPressed: () async {
              await ThemeModeService.instance.toggle();
              if (mounted) {
                setState(() {});
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () {
              if (_currentUser != null) {
                context.push(AppRoutes.clientProfilePath(_currentUser!.uid));
              } else {
                context.push(AppRoutes.profile);
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.redAccent),
            onPressed: _signOut,
          ),
        ],
      ),
      body: _currentUser == null
          ? const Center(child: CircularProgressIndicator())
          : StreamBuilder<DocumentSnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .doc(_currentUser!.uid)
                  .snapshots(),
              builder: (context, userSnapshot) {
                if (userSnapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (userSnapshot.hasError || !userSnapshot.hasData) {
                  return Center(child: Text('Error: ${userSnapshot.error}'));
                }
                final userData = userSnapshot.data!.data() as Map<String, dynamic>? ?? {};
                final userType = userData['userType'] ?? 'client';

                return StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('businesses')
                      .where('ownerId', isEqualTo: _currentUser!.uid)
                      .where('isActive', isEqualTo: true)
                      .snapshots(),
                  builder: (context, bizSnapshot) {
                    final bizDocs = bizSnapshot.data?.docs ?? [];
                    final businessCount = bizDocs.length;
                    final anyVerified = bizDocs.any(
                      (doc) => (doc.data() as Map<String, dynamic>)['isVerified'] == true,
                    );

                    return StreamBuilder<QuerySnapshot>(
                      stream: FirebaseFirestore.instance
                          .collection('chats')
                          .where('participants', arrayContains: _currentUser!.uid)
                          .snapshots(),
                      builder: (context, chatsSnapshot) {
                        final chatDocs = chatsSnapshot.data?.docs ?? [];
                        int unreadCount = 0;
                        for (final doc in chatDocs) {
                          final data = doc.data() as Map<String, dynamic>;
                          final lastMessageAt = data['lastMessageAt'] as Timestamp?;
                          final lastMessageSenderId = data['lastMessageSenderId'] as String?;
                          final lastReadAt = data['lastReadAt'] as Map<String, dynamic>? ?? {};
                          final lastReadForUser = lastReadAt[_currentUser!.uid] as Timestamp?;
                          final unread = lastMessageAt != null &&
                              (lastReadForUser == null ||
                                  lastMessageAt.toDate().isAfter(lastReadForUser.toDate()));
                          if (unread && lastMessageSenderId != _currentUser!.uid) {
                            unreadCount++;
                          }
                        }

                        return SingleChildScrollView(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          // Welcome Section
                          Card(
                            elevation: 4,
                            child: Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Spotlight your work!',
                                          style: Theme.of(context).textTheme.headlineSmall,
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          userData['name'] ?? 'User',
                                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                            color: AppColors.primary,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          userData['email'] ?? '',
                                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                            color: AppColors.grey,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Container(
                                    height: 64,
                                    width: 64,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: LinearGradient(
                                        colors: [
                                          AppColors.primary.withOpacity(0.9),
                                          AppColors.primary.withOpacity(0.6),
                                        ],
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                      ),
                                    ),
                                    child: _UserAvatar(
                                      name: (userData['name'] ?? 'User')
                                          .toString(),
                                      imageUrl:
                                          userData['imageUrl'] as String?,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          const SizedBox(height: 24),

                          // Quick Actions
                          Text(
                            'Quick Actions',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),

                          const SizedBox(height: 16),

                          GridView.count(
                            crossAxisCount: 2,
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            crossAxisSpacing: 16,
                            mainAxisSpacing: 16,
                            children: [
                              _buildActionCard(
                                icon: Icons.feed,
                                title: 'Spotlight Feed',
                                onTap: () {
                                  context.push(AppRoutes.feed);
                                },
                              ),
                              ..._getQuickActions(userType, unreadCount),
                            ],
                          ),

                          const SizedBox(height: 24),

                          // Status
                          Text(
                            'Status',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),

                          const SizedBox(height: 16),

                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Your Status',
                                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  _buildStatusRow(
                                    icon: Icons.verified_user,
                                    label: 'Profile',
                                    value: (userData['profileCompleted'] ?? false)
                                        ? 'Complete'
                                        : 'Incomplete',
                                  ),
                                  const SizedBox(height: 6),
                                  _buildStatusRow(
                                    icon: Icons.storefront,
                                    label: 'Pages',
                                    value: '$businessCount / 2 active',
                                  ),
                                  if (userType == 'business') ...[
                                    const SizedBox(height: 6),
                                    _buildStatusRow(
                                      icon: Icons.star,
                                      label: 'Verification',
                                      value: anyVerified ? 'Verified' : 'Not verified',
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
    );
  }

  List<Widget> _getQuickActions(String userType, int unreadCount) {
    if (userType == 'business') {
      return [
        _buildActionCard(
          icon: Icons.business,
          title: 'My Page',
          onTap: () {
            context.push(AppRoutes.businesses);
          },
        ),
        _buildActionCard(
          icon: Icons.message,
          title: 'Messages',
          badgeCount: unreadCount,
          onTap: () {
            context.push(AppRoutes.chats);
          },
        ),
        _buildActionCard(
          icon: Icons.search,
          title: 'Discover',
          onTap: () {
            context.push(AppRoutes.search);
          },
        ),
        _buildActionCard(
          icon: Icons.analytics,
          title: 'Insights',
          onTap: () {
            context.push(AppRoutes.analytics);
          },
        ),
      ];
    } else {
      return [
        _buildActionCard(
          icon: Icons.business,
          title: 'My Pages',
          onTap: () {
            context.push(AppRoutes.businesses);
          },
        ),
        _buildActionCard(
          icon: Icons.message,
          title: 'Messages',
          badgeCount: unreadCount,
          onTap: () {
            context.push(AppRoutes.chats);
          },
        ),
        _buildActionCard(
          icon: Icons.search,
          title: 'Discover',
          onTap: () {
            context.push(AppRoutes.search);
          },
        ),
        _buildActionCard(
          icon: Icons.bookmark,
          title: 'Saved',
          onTap: () {
            context.push(AppRoutes.favorites);
          },
        ),
      ];
    }
  }

  Widget _buildActionCard({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    int badgeCount = 0,
  }) {
    return Card(
      elevation: 2,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(
                    icon,
                    size: 48,
                    color: AppColors.primary,
                  ),
                  if (badgeCount > 0)
                    Positioned(
                      right: -4,
                      top: -4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          badgeCount.toString(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusRow({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppColors.primary),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(color: AppColors.grey),
        ),
        const Spacer(),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

class _UserAvatar extends StatelessWidget {
  const _UserAvatar({
    required this.name,
    required this.imageUrl,
  });

  final String name;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: imageUrl != null && imageUrl!.isNotEmpty
          ? Image.network(
              imageUrl!,
              fit: BoxFit.cover,
              width: 64,
              height: 64,
            )
          : Container(
              color: AppColors.primary,
              alignment: Alignment.center,
              child: Text(
                name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 22,
                ),
              ),
            ),
    );
  }
}
