import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/r2_storage_service.dart';
import '../../../core/theme/colors.dart';
import '../../../data/models/post_model.dart';
import 'package:businessfinder/features/chat/data/chat_repository.dart';
import '../business/post_detail_page.dart' as business_post;

class ClientProfilePage extends StatefulWidget {
  final String userId;

  const ClientProfilePage({super.key, required this.userId});

  @override
  State<ClientProfilePage> createState() => _ClientProfilePageState();
}

class _ClientProfilePageState extends State<ClientProfilePage> {
  static const int _maxBusinesses = 2;
  int _profileTab = 0;
  int _previousProfileTab = 0;
  final ValueNotifier<int> _profileTabNotifier = ValueNotifier<int>(0);
  int _collectionTab = 0;
  File? _selectedLogo;

  bool get _isSelf => FirebaseAuth.instance.currentUser?.uid == widget.userId;

  @override
  void dispose() {
    _profileTabNotifier.dispose();
    super.dispose();
  }

  Future<void> _followUser(String followerId, String followingId) async {
    await FirebaseFirestore.instance
        .collection('user_follows')
        .doc('${followerId}_$followingId')
        .set({
      'followerId': followerId,
      'followingId': followingId,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _unfollowUser(String followerId, String followingId) async {
    await FirebaseFirestore.instance
        .collection('user_follows')
        .doc('${followerId}_$followingId')
        .delete();
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> _followDocStream(
    String followerId,
    String followingId,
  ) {
    return FirebaseFirestore.instance
        .collection('user_follows')
        .doc('${followerId}_$followingId')
        .snapshots();
  }

  Future<void> _dialPhone(BuildContext context, String phone) async {
    final uri = Uri(scheme: 'tel', path: phone.replaceAll(RegExp(r'\s+'), ''));
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open dialer.')),
      );
    }
  }

  Future<void> _startChat(BuildContext context) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null || currentUser.uid == widget.userId) return;

    final currentUserDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(currentUser.uid)
        .get();
    final currentUserType =
        ((currentUserDoc.data() ?? {})['userType'] ?? 'client').toString();
    final repo = ChatRepository();

    if (currentUserType == 'business') {
      final businessesSnap = await FirebaseFirestore.instance
          .collection('businesses')
          .where('ownerId', isEqualTo: currentUser.uid)
          .where('isActive', isEqualTo: true)
          .limit(1)
          .get();
      if (businessesSnap.docs.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Create a page before messaging.')),
          );
        }
        return;
      }
      final chatId = await repo.createOrGetChat(
        businessId: businessesSnap.docs.first.id,
        businessOwnerId: currentUser.uid,
        clientId: widget.userId,
      );
      if (!context.mounted) return;
      context.push(AppRoutes.chatDetailPath(chatId));
      return;
    }

    final chatId = await repo.createOrGetDirectChat(
      userAId: currentUser.uid,
      userBId: widget.userId,
    );
    if (!context.mounted) return;
    context.push(AppRoutes.chatDetailPath(chatId));
  }

  Future<int> _activeBusinessCount() async {
    final snap = await FirebaseFirestore.instance
        .collection('businesses')
        .where('ownerId', isEqualTo: widget.userId)
        .where('isActive', isEqualTo: true)
        .get();
    return snap.docs.length;
  }

  void _showPremiumDialog(String title, String message) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF141821) : Colors.white,
            borderRadius: BorderRadius.circular(24),
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
                child: const Icon(Icons.auto_awesome, color: Colors.white),
              ),
              const SizedBox(height: 12),
              Text(title,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.grey)),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
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
                              content: Text('Premium upgrade is coming soon!')),
                        );
                      },
                      child: const Text('Go Premium'),
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

  Future<void> _createPage() async {
    if (!_isSelf) return;
    final count = await _activeBusinessCount();
    if (count >= _maxBusinesses) {
      _showPremiumDialog('Go Premium',
          'Free creators can run up to 2 active pages. Upgrade to add more.');
      return;
    }
    if (!mounted) return;
    context.push(AppRoutes.businessSetup);
  }

  Future<void> _setBusinessActive(String businessId, bool isActive) async {
    await FirebaseFirestore.instance
        .collection('businesses')
        .doc(businessId)
        .update({
      'isActive': isActive,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _pickLogo(String businessId) async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    setState(() => _selectedLogo = File(picked.path));
    try {
      final url = await R2StorageService.instance.uploadImage(
        bucket: 'profile-images',
        path: '$businessId/logo_${DateTime.now().millisecondsSinceEpoch}.jpg',
        bytes: await _selectedLogo!.readAsBytes(),
      );
      await FirebaseFirestore.instance
          .collection('businesses')
          .doc(businessId)
          .update({
        if (url != null) 'imageUrl': url,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (url != null) {
        final posts = await FirebaseFirestore.instance
            .collection('posts')
            .where('businessId', isEqualTo: businessId)
            .get();
        final batch = FirebaseFirestore.instance.batch();
        for (final doc in posts.docs) {
          batch.update(doc.reference, {'businessImageUrl': url});
        }
        await batch.commit();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Logo upload failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _selectedLogo = null);
    }
  }

  Future<void> _unsave(String postId) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;
    await FirebaseFirestore.instance
        .collection('users')
        .doc(currentUser.uid)
        .collection('favorites')
        .doc(postId)
        .delete();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(widget.userId)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snapshot.hasData || !snapshot.data!.exists) {
            return const Center(child: Text('User not found'));
          }

          final data = snapshot.data!.data() as Map<String, dynamic>;
          final name = (data['name'] ?? 'User').toString();
          final imageUrl = (data['imageUrl'] ?? '').toString();
          final bio = (data['bio'] ?? '').toString();
          final phone = (data['phone'] ?? '').toString();
          final email = (data['email'] ?? '').toString();

          final isDesktop = MediaQuery.of(context).size.width >= 1200;

          final profileHeader = _buildProfileHeader(
            context: context,
            name: name,
            imageUrl: imageUrl,
            bio: bio,
            phone: phone,
            isDark: isDark,
            currentUserId: currentUserId,
          );

          final profileAbout = (email.isNotEmpty || phone.isNotEmpty)
              ? _buildProfileAbout(
                  context: context, email: email, phone: phone, isDark: isDark)
              : null;

          final profileTabs = ValueListenableBuilder<int>(
            valueListenable: _profileTabNotifier,
            builder: (context, currentTab, _) {
              return Column(
                children: [
                  _profileTabs(currentTab),
                  const SizedBox(height: 16),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: Column(
                      children: [
                        _animatedProfilePane(
                          index: 0,
                          child: TickerMode(
                            enabled: currentTab == 0,
                            child: _postsSection(context),
                          ),
                        ),
                        _animatedProfilePane(
                          index: 1,
                          child: TickerMode(
                            enabled: currentTab == 1,
                            child: _pagesSection(context),
                          ),
                        ),
                        _animatedProfilePane(
                          index: 2,
                          child: TickerMode(
                            enabled: currentTab == 2,
                            child: _hubSection(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          );

          if (!isDesktop) {
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  profileHeader,
                  const SizedBox(height: 14),
                  if (profileAbout != null) profileAbout,
                  if (profileAbout != null) const SizedBox(height: 22),
                  profileTabs,
                ],
              ),
            );
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 340,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      profileHeader,
                      if (profileAbout != null) const SizedBox(height: 14),
                      if (profileAbout != null) profileAbout,
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      profileTabs,
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 300,
                  child: _buildProfileRecommendations(
                    currentUserId: currentUserId,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _circleAction(IconData icon, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(28),
      child: Opacity(
        opacity: onTap == null ? 0.4 : 1,
        child: CircleAvatar(
          radius: 22,
          backgroundColor: AppColors.lightGrey,
          child: Icon(icon, color: AppColors.primary),
        ),
      ),
    );
  }

  Widget _animatedProfilePane({
    required int index,
    required Widget child,
  }) {
    final isActive = _profileTab == index;
    final movingForward = _profileTab >= _previousProfileTab;
    final beginOffset = Offset(
      isActive ? (movingForward ? 0.08 : -0.08) : 0,
      0,
    );

    return Visibility(
      visible: isActive,
      maintainState: true,
      maintainAnimation: true,
      maintainSize: false,
      child: TweenAnimationBuilder<Offset>(
        key: ValueKey('profile-pane-$_profileTab'),
        tween: Tween<Offset>(
          begin: beginOffset,
          end: Offset.zero,
        ),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        child: child,
        builder: (context, offset, paneChild) {
          return Transform.translate(
            offset: Offset(offset.dx * 120, 0),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 180),
              opacity: isActive ? 1 : 0,
              child: paneChild,
            ),
          );
        },
      ),
    );
  }

  Widget _aboutRow(IconData icon, String value) {
    return Row(
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 8),
        Expanded(
            child: Text(value, style: const TextStyle(color: AppColors.grey))),
      ],
    );
  }

  Widget _profileStatsRow(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('user_follows')
          .where('followingId', isEqualTo: widget.userId)
          .snapshots(),
      builder: (context, followersSnap) {
        final followersCount = followersSnap.data?.docs.length ?? 0;
        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('user_follows')
              .where('followerId', isEqualTo: widget.userId)
              .snapshots(),
          builder: (context, followingSnap) {
            final followingUsers = followingSnap.data?.docs.length ?? 0;
            return StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('page_follows')
                  .where('followerId', isEqualTo: widget.userId)
                  .snapshots(),
              builder: (context, pageFollowingSnap) {
                final followingPages = pageFollowingSnap.data?.docs.length ?? 0;
                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    GestureDetector(
                      onTap: () => context
                          .push(AppRoutes.userFollowersPath(widget.userId)),
                      child: _statPill('Followers', followersCount),
                    ),
                    const SizedBox(width: 12),
                    GestureDetector(
                      onTap: () => context
                          .push(AppRoutes.userFollowingPath(widget.userId)),
                      onLongPress: () {
                        final isDark =
                            Theme.of(context).brightness == Brightness.dark;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                                '$followingUsers users, $followingPages pages'),
                            backgroundColor:
                                isDark ? const Color(0xFF151A24) : null,
                          ),
                        );
                      },
                      child: _statPill(
                          'Following', followingUsers + followingPages),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _statPill(String label, int value) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : Colors.black.withOpacity(0.04),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: isDark ? Colors.white12 : Colors.black12),
      ),
      child: Column(
        children: [
          Text('$value', style: const TextStyle(fontWeight: FontWeight.bold)),
          Text(label,
              style: const TextStyle(fontSize: 11, color: AppColors.grey)),
        ],
      ),
    );
  }

  Widget _buildProfileHeader({
    required BuildContext context,
    required String name,
    required String imageUrl,
    required String bio,
    required String phone,
    required bool isDark,
    required String? currentUserId,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF151A24) : Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: isDark ? Colors.white10 : Colors.black12),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _circleAction(Icons.call,
                  phone.isEmpty ? null : () => _dialPhone(context, phone)),
              const SizedBox(width: 18),
              CircleAvatar(
                radius: 54,
                backgroundColor: AppColors.primary,
                backgroundImage:
                    imageUrl.isNotEmpty ? NetworkImage(imageUrl) : null,
                child: imageUrl.isEmpty
                    ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 30,
                            fontWeight: FontWeight.bold))
                    : null,
              ),
              const SizedBox(width: 18),
              _circleAction(
                  Icons.message,
                  FirebaseAuth.instance.currentUser == null
                      ? null
                      : () => _startChat(context)),
            ],
          ),
          const SizedBox(height: 12),
          Text(name,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          if (bio.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(bio,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.grey)),
          ],
          const SizedBox(height: 12),
          _profileStatsRow(context),
          const SizedBox(height: 14),
          if (_isSelf)
            OutlinedButton(
              onPressed: () => context.push(AppRoutes.profile),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: const BorderSide(color: AppColors.primary),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('Edit Profile'),
            ),
          if (!_isSelf && currentUserId != null)
            StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: _followDocStream(currentUserId, widget.userId),
              builder: (context, followSnap) {
                final isFollowing = followSnap.data?.exists == true;
                return ElevatedButton(
                  onPressed: () => isFollowing
                      ? _unfollowUser(currentUserId, widget.userId)
                      : _followUser(currentUserId, widget.userId),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        isFollowing ? Colors.transparent : AppColors.primary,
                    foregroundColor:
                        isFollowing ? AppColors.primary : Colors.white,
                    elevation: 0,
                    side: isFollowing
                        ? const BorderSide(color: AppColors.primary)
                        : BorderSide.none,
                  ),
                  child: Text(isFollowing ? 'Following' : 'Follow'),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildProfileAbout({
    required BuildContext context,
    required String email,
    required String phone,
    required bool isDark,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF151A24) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: isDark ? Colors.white10 : Colors.black12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('About',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          if (email.isNotEmpty) _aboutRow(Icons.email_outlined, email),
          if (email.isNotEmpty && phone.isNotEmpty) const SizedBox(height: 8),
          if (phone.isNotEmpty) _aboutRow(Icons.phone_outlined, phone),
        ],
      ),
    );
  }

  Widget _buildProfileRecommendations({String? currentUserId}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF151A24)
            : Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white10
                : Colors.black12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Who to follow',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('users')
                .where('uid', isNotEqualTo: currentUserId ?? '')
                .limit(5)
                .snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final docs = snap.data?.docs ?? [];
              if (docs.isEmpty) {
                return const Text('No suggestions right now.',
                    style: TextStyle(color: AppColors.grey));
              }
              return Column(
                children: docs.map((doc) {
                  final user = doc.data() as Map<String, dynamic>;
                  final userName = (user['name'] ?? 'Creator').toString();
                  final userId = doc.id;
                  final avatar = (user['imageUrl'] ?? '').toString();
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 16,
                          backgroundColor: AppColors.lightGrey,
                          backgroundImage:
                              avatar.isNotEmpty ? NetworkImage(avatar) : null,
                          child: avatar.isEmpty
                              ? Text(
                                  userName.isNotEmpty
                                      ? userName[0].toUpperCase()
                                      : '?',
                                  style: const TextStyle(color: Colors.white))
                              : null,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                            child: Text(userName,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600))),
                        FilledButton(
                          onPressed:
                              currentUserId == null || currentUserId == userId
                                  ? null
                                  : () => _followUser(currentUserId, userId),
                          style: FilledButton.styleFrom(
                              minimumSize: const Size(70, 30)),
                          child: const Text('Follow'),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _pagesSection(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('businesses')
          .where('ownerId', isEqualTo: widget.userId)
          .snapshots(),
      builder: (context, snapshot) {
        final docs = [...(snapshot.data?.docs ?? [])];
        docs.sort((a, b) {
          final aActive =
              ((a.data() as Map<String, dynamic>)['isActive'] != false);
          final bActive =
              ((b.data() as Map<String, dynamic>)['isActive'] != false);
          if (aActive != bActive) return aActive ? -1 : 1;
          return 0;
        });
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Pages',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const Spacer(),
                if (_isSelf)
                  TextButton.icon(
                      onPressed: _createPage,
                      icon: const Icon(Icons.add_circle_outline),
                      label: const Text('Add page')),
              ],
            ),
            const SizedBox(height: 10),
            if (docs.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF151A24) : Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                      color: isDark ? Colors.white10 : Colors.black12),
                ),
                child: Text(
                  _isSelf
                      ? 'No pages yet. Build your first creator page.'
                      : 'No pages yet',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.grey),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: docs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final doc = docs[index];
                  final data = doc.data() as Map<String, dynamic>;
                  final imageUrl = (data['imageUrl'] ?? '').toString();
                  final name = (data['name'] ?? 'Page').toString();
                  final category = (data['category'] ?? '').toString();
                  final isActive = data['isActive'] != false;
                  final isVerified = data['isVerified'] == true;
                  return InkWell(
                    onTap: () =>
                        context.push(AppRoutes.businessProfilePath(doc.id)),
                    borderRadius: BorderRadius.circular(20),
                    child: Ink(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF151A24) : Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: isDark ? Colors.white10 : Colors.black12),
                      ),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: SizedBox(
                              height: 72,
                              width: 72,
                              child: imageUrl.isNotEmpty
                                  ? Image.network(imageUrl, fit: BoxFit.cover)
                                  : Container(
                                      color:
                                          AppColors.primary.withOpacity(0.15),
                                      alignment: Alignment.center,
                                      child: Text(
                                          name.isNotEmpty
                                              ? name[0].toUpperCase()
                                              : '?',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 24)),
                                    ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                        child: Text(name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 16))),
                                    if (isVerified)
                                      const Icon(Icons.verified,
                                          color: Color(0xFF61D1ED), size: 18),
                                  ],
                                ),
                                if (category.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(category,
                                      style: const TextStyle(
                                          color: AppColors.grey, fontSize: 12)),
                                ],
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: (isActive
                                            ? AppColors.primary
                                            : Colors.orange)
                                        .withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    isActive ? 'Active' : 'Hidden',
                                    style: TextStyle(
                                        color: isActive
                                            ? AppColors.primary
                                            : Colors.orange,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (_isSelf)
                            PopupMenuButton<String>(
                              onSelected: (value) {
                                if (value == 'edit') {
                                  context.push(
                                    '${AppRoutes.businessSetup}?businessId=${doc.id}',
                                  );
                                }
                                if (value == 'logo') _pickLogo(doc.id);
                                if (value == 'toggle') {
                                  _setBusinessActive(doc.id, !isActive);
                                }
                                if (value == 'verify') {
                                  _showPremiumDialog('Premium Required',
                                      'Verification is available on Premium. Upgrade when you are ready.');
                                }
                              },
                              itemBuilder: (context) => [
                                const PopupMenuItem(
                                    value: 'edit', child: Text('Edit')),
                                const PopupMenuItem(
                                    value: 'logo', child: Text('Update logo')),
                                PopupMenuItem(
                                    value: 'toggle',
                                    child: Text(isActive
                                        ? 'Hide page'
                                        : 'Unhide page')),
                                const PopupMenuItem(
                                    value: 'verify',
                                    child: Text('Verify (Premium)')),
                              ],
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
          ],
        );
      },
    );
  }

  Widget _profileTabs(int currentTab) {
    final labels = _isSelf
        ? const ['Posts', 'Pages', 'Creator Hub']
        : const ['Posts', 'Pages', 'Collections'];
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF151A24)
            : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.white10
              : Colors.black12,
        ),
      ),
      child: Row(
        children: List.generate(
          labels.length,
          (index) => Expanded(
            child: GestureDetector(
              onTap: () {
                if (_profileTab == index) return;
                _previousProfileTab = _profileTab;
                _profileTab = index;
                _profileTabNotifier.value = index;
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: currentTab == index
                      ? AppColors.primary.withOpacity(0.14)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  labels[index],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: currentTab == index ? AppColors.primary : null,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _postsSection(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('posts')
          .where('ownerId', isEqualTo: widget.userId)
          .orderBy('createdAt', descending: true)
          .snapshots(),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) {
          return _emptyCard(
            _isSelf
                ? 'No posts yet. Share your first post.'
                : 'No posts yet.',
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  _isSelf ? 'Your Posts' : 'Posts',
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  '${docs.length}',
                  style: const TextStyle(
                    color: AppColors.grey,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: docs.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemBuilder: (context, index) {
                final post = Post.fromFirestore(docs[index]);
                return InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => business_post.PostDetailPage(
                        post: post,
                        initialMediaIndex: 0,
                      ),
                    ),
                  ),
                  child: _postGridPreview(post),
                );
              },
            ),
          ],
        );
      },
    );
  }

  Widget _insightsSection(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('businesses')
          .where('ownerId', isEqualTo: widget.userId)
          .where('isActive', isEqualTo: true)
          .snapshots(),
      builder: (context, snapshot) {
        final activePages = snapshot.data?.docs.length ?? 0;
        if (activePages == 0) {
          return const SizedBox.shrink();
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Insights',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            InkWell(
              onTap: () => context.push(AppRoutes.analytics),
              borderRadius: BorderRadius.circular(20),
              child: Ink(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF151A24) : Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isDark ? Colors.white10 : Colors.black12,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 54,
                      height: 54,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        gradient: LinearGradient(
                          colors: [
                            AppColors.primary.withOpacity(0.95),
                            AppColors.primary.withOpacity(0.55),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                      child: const Icon(
                        Icons.insights_rounded,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Creator Insights',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            activePages == 1
                                ? 'Track post performance, saved content, and chat activity for your page.'
                                : 'Track performance across your $activePages active pages from one place.',
                            style: const TextStyle(
                              color: AppColors.grey,
                              fontSize: 13,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Icon(Icons.chevron_right),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _collectionsSection(BuildContext context) {
    const tabs = ['Top Creators', 'Saved'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(_isSelf ? 'Collections' : 'Top creators liked',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const Spacer(),
            if (_isSelf)
              Wrap(
                spacing: 8,
                children: List.generate(
                  tabs.length,
                  (index) => ChoiceChip(
                    label: Text(tabs[index]),
                    selected: _collectionTab == index,
                    onSelected: (_) => setState(() => _collectionTab = index),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (!_isSelf || _collectionTab == 0)
          _likedBusinessesGrid()
        else
          _savedPostsGrid(),
      ],
    );
  }

  Widget _hubSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_isSelf) _insightsSection(context),
        if (_isSelf) const SizedBox(height: 22),
        _collectionsSection(context),
      ],
    );
  }

  Widget _likedBusinessesGrid() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('posts')
          .where('likes', arrayContains: widget.userId)
          .snapshots(),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) return _emptyCard('No creator activity yet.');
        final seen = <String>{};
        final items = <Map<String, String>>[];
        for (final doc in docs) {
          final data = doc.data() as Map<String, dynamic>;
          final businessId = (data['businessId'] ?? '').toString();
          if (businessId.isEmpty || seen.contains(businessId)) continue;
          seen.add(businessId);
          items.add({
            'id': businessId,
            'name': (data['businessName'] ?? 'Creator').toString(),
            'imageUrl': (data['businessImageUrl'] ?? '').toString(),
          });
        }
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: items.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3, crossAxisSpacing: 8, mainAxisSpacing: 8),
          itemBuilder: (context, index) => InkWell(
            onTap: () => context
                .push(AppRoutes.businessProfilePath(items[index]['id']!)),
            child: _squarePreview(
                items[index]['imageUrl']!, items[index]['name']!),
          ),
        );
      },
    );
  }

  Widget _savedPostsGrid() {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return _emptyCard('Sign in to see saved posts.');
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser.uid)
          .collection('favorites')
          .orderBy('createdAt', descending: true)
          .snapshots(),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) return _emptyCard('No saved posts yet.');
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: docs.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3, crossAxisSpacing: 8, mainAxisSpacing: 8),
          itemBuilder: (context, index) => StreamBuilder<DocumentSnapshot>(
            stream: FirebaseFirestore.instance
                .collection('posts')
                .doc(docs[index].id)
                .snapshots(),
            builder: (context, postSnap) {
              if (!postSnap.hasData || !postSnap.data!.exists) {
                return InkWell(
                    onTap: () => _unsave(docs[index].id),
                    child: _squarePreview('', 'Deleted'));
              }
              final post = Post.fromFirestore(postSnap.data!);
              return InkWell(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => business_post.PostDetailPage(
                        post: post, initialMediaIndex: 0))),
                child: Stack(
                  children: [
                    Positioned.fill(child: _savedPreview(post)),
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Material(
                        color: Colors.black.withOpacity(0.38),
                        borderRadius: BorderRadius.circular(999),
                        child: InkWell(
                          onTap: () => _unsave(post.id),
                          borderRadius: BorderRadius.circular(999),
                          child: const Padding(
                            padding: EdgeInsets.all(6),
                            child: Icon(Icons.bookmark_remove,
                                size: 16, color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _emptyCard(String text) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF151A24) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: isDark ? Colors.white10 : Colors.black12),
      ),
      child: Text(text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.grey)),
    );
  }

  Widget _squarePreview(String imageUrl, String fallback) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.lightGrey,
        borderRadius: BorderRadius.circular(12),
        image: imageUrl.isNotEmpty
            ? DecorationImage(image: NetworkImage(imageUrl), fit: BoxFit.cover)
            : null,
      ),
      child: imageUrl.isEmpty
          ? Center(
              child: Text(fallback.isNotEmpty ? fallback[0].toUpperCase() : '?',
                  style: const TextStyle(fontWeight: FontWeight.bold)))
          : null,
    );
  }

  Widget _savedPreview(Post post) {
    final media = post.media;
    String? previewUrl;
    var isVideo = false;
    if (media.isNotEmpty) {
      previewUrl = media.first.url;
      isVideo = media.first.isVideo;
    } else if (post.imageUrl != null && post.imageUrl!.isNotEmpty) {
      previewUrl = post.imageUrl;
    } else if (post.videoUrl != null && post.videoUrl!.isNotEmpty) {
      previewUrl = post.videoUrl;
      isVideo = true;
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (previewUrl == null)
            Container(
                color: AppColors.lightGrey,
                child: const Icon(Icons.image_outlined, color: AppColors.grey))
          else if (isVideo)
            _VideoThumb(url: previewUrl)
          else
            Image.network(previewUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                    color: AppColors.lightGrey,
                    child: const Icon(Icons.broken_image_outlined))),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(8, 20, 8, 8),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black54]),
              ),
              child: Text(
                post.content.isEmpty ? 'Saved post' : post.content,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _postGridPreview(Post post) {
    final media = post.media;
    String? previewUrl;
    var isVideo = false;

    if (media.isNotEmpty) {
      previewUrl = media.first.url;
      isVideo = media.first.isVideo;
    } else if (post.imageUrl != null && post.imageUrl!.isNotEmpty) {
      previewUrl = post.imageUrl;
    } else if (post.videoUrl != null && post.videoUrl!.isNotEmpty) {
      previewUrl = post.videoUrl;
      isVideo = true;
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (previewUrl == null)
            Container(
              color: AppColors.lightGrey,
              alignment: Alignment.center,
              child: Text(
                post.content.isNotEmpty ? post.content[0].toUpperCase() : '?',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                ),
              ),
            )
          else if (isVideo)
            _VideoThumb(url: previewUrl)
          else
            Image.network(
              previewUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                color: AppColors.lightGrey,
                child: const Icon(Icons.broken_image_outlined),
              ),
            ),
          if (isVideo)
            const Positioned(
              top: 6,
              right: 6,
              child: Icon(
                Icons.play_circle_fill,
                color: Colors.white,
                size: 18,
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(6, 18, 6, 6),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black54,
                  ],
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.favorite_border,
                      color: Colors.white, size: 12),
                  const SizedBox(width: 4),
                  Text(
                    '${post.likeCount}',
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                  const SizedBox(width: 10),
                  const Icon(Icons.chat_bubble_outline,
                      color: Colors.white, size: 12),
                  const SizedBox(width: 4),
                  Text(
                    '${post.commentCount}',
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VideoThumb extends StatelessWidget {
  const _VideoThumb({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: VideoThumbnail.thumbnailData(
          video: url,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 300,
          quality: 70),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) {
          return Container(
              color: Colors.black26,
              child: const Center(
                  child: Icon(Icons.play_circle_fill, color: Colors.white70)));
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            Image.memory(bytes, fit: BoxFit.cover),
            const Center(
                child: Icon(Icons.play_circle_fill, color: Colors.white70)),
          ],
        );
      },
    );
  }
}
