import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/colors.dart';
import '../../../data/repositories/chat_repository.dart';

class ClientProfilePage extends StatelessWidget {
  final String userId;

  const ClientProfilePage({super.key, required this.userId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Client Profile')),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance.collection('users').doc(userId).snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snapshot.hasData || !snapshot.data!.exists) {
            return const Center(child: Text('User not found'));
          }

          final data = snapshot.data!.data() as Map<String, dynamic>;
          final name = (data['name'] ?? 'Client').toString();
          final imageUrl = data['imageUrl'] as String?;
          final bio = (data['bio'] ?? '').toString();
          final phone = (data['phone'] ?? '').toString();

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                CircleAvatar(
                  radius: 48,
                  backgroundColor: AppColors.primary,
                  backgroundImage: imageUrl != null ? NetworkImage(imageUrl) : null,
                  child: imageUrl == null
                      ? Text(
                          name.isNotEmpty ? name[0].toUpperCase() : '?',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                          ),
                        )
                      : null,
                ),
                const SizedBox(height: 12),
                Text(
                  name,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                if (bio.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    bio,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.grey),
                  ),
                ],
                const SizedBox(height: 16),
                if (FirebaseAuth.instance.currentUser?.uid == userId)
                  TextButton(
                    onPressed: () {
                      context.push(AppRoutes.profile);
                    },
                    child: const Text('Edit profile'),
                  ),
                const SizedBox(height: 8),
                _actionRow(context, phone),
                const SizedBox(height: 24),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Top businesses liked',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _likedBusinessesGrid(context),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _actionRow(BuildContext context, String phone) {
    final currentUser = FirebaseAuth.instance.currentUser;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _circleAction(
          icon: Icons.call,
          onTap: phone.isEmpty
              ? null
              : () async {
                  final uri = Uri.parse('tel:$phone');
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri);
                  }
                },
          label: 'Call',
        ),
        const SizedBox(width: 16),
        _circleAction(
          icon: Icons.message,
          onTap: currentUser == null ? null : () => _startChat(context),
          label: 'Message',
        ),
      ],
    );
  }

  Widget _circleAction({
    required IconData icon,
    required VoidCallback? onTap,
    required String label,
  }) {
    return Column(
      children: [
        InkWell(
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
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: AppColors.grey),
        ),
      ],
    );
  }

  Future<void> _startChat(BuildContext context) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;
    if (currentUser.uid == userId) return;

    final currentUserDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(currentUser.uid)
        .get();
    final currentUserType =
        (currentUserDoc.data() ?? {})['userType'] ??
            'client';

    final repo = ChatRepository();

    if (currentUserType == 'business') {
      // Business users can message clients. Use their first active business.
      final businessesSnap = await FirebaseFirestore.instance
          .collection('businesses')
          .where('ownerId', isEqualTo: currentUser.uid)
          .where('isActive', isEqualTo: true)
          .limit(1)
          .get();

      if (businessesSnap.docs.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Create a business before messaging.')),
          );
        }
        return;
      }

      final businessId = businessesSnap.docs.first.id;
      final chatId = await repo.createOrGetChat(
        businessId: businessId,
        businessOwnerId: currentUser.uid,
        clientId: userId,
      );
      if (!context.mounted) return;
      context.push(AppRoutes.chatDetailPath(chatId));
      return;
    }

    final chatId = await repo.createOrGetDirectChat(
      userAId: currentUser.uid,
      userBId: userId,
    );
    if (!context.mounted) return;
    context.push(AppRoutes.chatDetailPath(chatId));
  }

  Widget _likedBusinessesGrid(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('posts')
          .where('likes', arrayContains: userId)
          .snapshots(),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) {
          return const Text('No likes yet');
        }

        final seen = <String>{};
        final items = <_BusinessItem>[];
        for (final doc in docs) {
          final data = doc.data() as Map<String, dynamic>;
          final businessId = (data['businessId'] ?? '').toString();
          if (businessId.isEmpty || seen.contains(businessId)) continue;
          seen.add(businessId);
          items.add(_BusinessItem(
            id: businessId,
            name: (data['businessName'] ?? 'Business').toString(),
            imageUrl: data['businessImageUrl'] as String?,
          ));
        }

        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return InkWell(
              onTap: () => context.push(AppRoutes.businessProfilePath(item.id)),
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.lightGrey,
                  borderRadius: BorderRadius.circular(8),
                  image: item.imageUrl != null
                      ? DecorationImage(
                          image: NetworkImage(item.imageUrl!),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                child: item.imageUrl == null
                    ? Center(
                        child: Text(
                          item.name.isNotEmpty ? item.name[0] : '?',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      )
                    : null,
              ),
            );
          },
        );
      },
    );
  }
}

class _BusinessItem {
  final String id;
  final String name;
  final String? imageUrl;

  _BusinessItem({required this.id, required this.name, required this.imageUrl});
}
