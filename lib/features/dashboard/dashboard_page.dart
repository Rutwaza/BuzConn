import 'package:flutter/material.dart';
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
  Map<String, dynamic>? _userData;

  @override
  void initState() {
    super.initState();
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
          _userData = userData;
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
        title: const Text('Dashboard'),
        leading: StreamBuilder<QuerySnapshot>(
          stream: _currentUser == null
              ? const Stream.empty()
              : FirebaseFirestore.instance
                  .collection('notifications')
                  .where('toUserId', isEqualTo: _currentUser!.uid)
                  .where('readAt', isEqualTo: null)
                  .snapshots(),
          builder: (context, notifSnap) {
            final docs = notifSnap.data?.docs ?? [];
            final count = docs
                .where((d) => (d.data() as Map<String, dynamic>)['hidden'] != true)
                .length;
            return IconButton(
              onPressed: () async {
                context.push(AppRoutes.notifications);
              },
              icon: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Icon(Icons.notifications),
                  if (count > 0)
                    Positioned(
                      right: -6,
                      top: -6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          count.toString(),
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
            );
          },
        ),
        actions: [
          IconButton(
            icon: Icon(
              ThemeModeService.instance.mode.value == ThemeMode.dark
                  ? Icons.light_mode
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
            icon: const Icon(Icons.logout),
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
                                          'Welcome back!',
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
                                    child: Center(
                                      child: userType == 'business'
                                          ? Icon(
                                              Icons.star,
                                              color: anyVerified
                                                  ? const Color(0xFFFFD700)
                                                  : const Color(0xFFCD7F32),
                                              size: 30,
                                            )
                                          : const Text(
                                              '😊',
                                              style: TextStyle(fontSize: 26),
                                            ),
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
                                title: 'Business Feed',
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
                                    label: 'Businesses',
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
          title: 'My Business',
          onTap: () {
            context.push(AppRoutes.businesses);
          },
        ),
        _buildActionCard(
          icon: Icons.traffic,
          title: 'Traffic Management',
          onTap: () {
            context.push(AppRoutes.trafficManagement);
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
          title: 'Find Services',
          onTap: () {
            context.push(AppRoutes.search);
          },
        ),
        _buildActionCard(
          icon: Icons.analytics,
          title: 'Analytics',
          onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Analytics coming soon!')),
            );
          },
        ),
      ];
    } else {
      return [
        _buildActionCard(
          icon: Icons.business,
          title: 'My Businesses',
          onTap: () {
            context.push(AppRoutes.businesses);
          },
        ),
        _buildActionCard(
          icon: Icons.traffic,
          title: 'Traffic Management',
          onTap: () {
            context.push(AppRoutes.trafficManagement);
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
          title: 'Find Services',
          onTap: () {
            context.push(AppRoutes.search);
          },
        ),
        _buildActionCard(
          icon: Icons.favorite,
          title: 'Favorites',
          onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Favorites coming soon!')),
            );
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
