import 'dart:convert';
import 'package:businessfinder/core/i18n/tr.dart';
import 'package:businessfinder/features/shop/ui/catalog_page.dart';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:url_launcher/url_launcher.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/theme/colors.dart';
import '../../../data/models/post_model.dart';
import 'post_detail_page.dart';
import 'package:businessfinder/features/chat/data/chat_repository.dart';
import '../../../core/constants/app_constants.dart';

class BusinessProfilePage extends StatefulWidget {
  final String businessId;

  const BusinessProfilePage({super.key, required this.businessId});

  @override
  State<BusinessProfilePage> createState() => _BusinessProfilePageState();
}

class _BusinessProfilePageState extends State<BusinessProfilePage> {
  final Map<String, Future<Uint8List?>> _thumbCache = {};
  final Map<String, Future<LatLng?>> _locationCache = {};

  bool get _supportsNativeGoogleMap =>
      !AppConstants.pauseGoogleMaps &&
      (kIsWeb ||
          defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  void _handleBackNavigation() {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).maybePop();
      return;
    }
    context.go(AppRoutes.dashboard);
  }

  Future<Uint8List?> _getVideoThumbnail(String url) {
    return _thumbCache.putIfAbsent(
      url,
      () async {
        if (Platform.isWindows) {
          // VideoThumbnail doesn't work on Windows, return null
          return null;
        }
        return VideoThumbnail.thumbnailData(
          video: url,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 420,
          quality: 70,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('businesses')
            .doc(widget.businessId)
            .snapshots(),
        builder: (context, businessSnapshot) {
          if (businessSnapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!businessSnapshot.hasData || !businessSnapshot.data!.exists) {
            return Center(child: Text(tr('Page not found')));
          }

          final raw = businessSnapshot.data!.data();
          if (raw == null) {
            return Center(child: Text(tr('Page not found')));
          }
          final business = raw as Map<String, dynamic>;
          final name = business['name'] ?? 'Page';
          final imageUrl = business['imageUrl'] as String?;
          final category = business['category'] ?? '';
          final phone = business['phone'] ?? '';
          final email = (business['email'] ?? '').toString().trim();
          final description =
              (business['description'] ?? '').toString().trim();
          final address = (business['address'] ?? business['location'] ?? '')
              .toString()
              .trim();
          final mapsLink = (business['googleMapsLink'] ?? '').toString().trim();
          final isVerified = business['isVerified'] == true;
          final ownerId = business['ownerId'] ?? '';
          final currentUserId = FirebaseAuth.instance.currentUser?.uid;
          final isOwner = currentUserId == ownerId;
          final isDesktop = MediaQuery.of(context).size.width >= 1100;

          if (isDesktop) {
            return _buildDesktopLayout(
              business: business,
              name: name.toString(),
              imageUrl: imageUrl,
              category: category.toString(),
              phone: phone.toString(),
              isVerified: isVerified,
              ownerId: ownerId.toString(),
              currentUserId: currentUserId,
              isOwner: isOwner,
            );
          }

          return CustomScrollView(
            slivers: [
              SliverAppBar(
                pinned: true,
                expandedHeight: 230,
                leading: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: CircleAvatar(
                    backgroundColor: Colors.black.withValues(alpha: 0.28),
                    child: IconButton(
                      icon: const Icon(
                        Icons.arrow_back_rounded,
                        color: Colors.white,
                      ),
                      onPressed: _handleBackNavigation,
                    ),
                  ),
                ),
                title: const Text(''),
                flexibleSpace: FlexibleSpaceBar(
                  background: Container(
                    padding: const EdgeInsets.fromLTRB(16, 52, 16, 8),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _circleIconButton(
                              icon: Icons.call,
                              onTap: phone.toString().isEmpty
                                  ? null
                                  : () async {
                                      await _dialPhone(context, phone);
                                    },
                            ),
                            const SizedBox(width: 8),
                            CircleAvatar(
                              radius: 36,
                              backgroundColor: AppColors.primary,
                              backgroundImage:
                                  imageUrl != null && imageUrl.isNotEmpty
                                      ? CachedNetworkImageProvider(imageUrl)
                                      : null,
                              child: null,
                            ),
                            const SizedBox(width: 8),
                            _circleIconButton(
                              icon: Icons.message,
                              onTap: () => _openBusinessChat(ownerId.toString()),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 240),
                              child: Text(
                                name.toString(),
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            if (isVerified)
                              const Icon(
                                Icons.verified,
                                color: Colors.green,
                                size: 16,
                              ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          isVerified ? 'Verified page' : 'Not verified',
                          style: TextStyle(
                            color: isVerified ? Colors.green : AppColors.grey,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (description.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(
                            description,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.grey,
                              fontSize: 12,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                  child: Column(
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Theme.of(context).brightness == Brightness.dark
                              ? const Color(0xFF151A24)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Theme.of(context).brightness == Brightness.dark
                                ? Colors.white10
                                : Colors.black12,
                          ),
                        ),
                        child: StreamBuilder<QuerySnapshot>(
                          stream: _pageFollowers(widget.businessId),
                          builder: (context, followersSnap) {
                            final followersCount =
                                followersSnap.data?.docs.length ?? 0;
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Align(
                                  alignment: Alignment.center,
                                  child: Text(
                                    tr('About this page'),
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    _StatPill(
                                      label: tr('Followers'),
                                      value: followersCount,
                                    ),
                                    ElevatedButton.icon(
                                      onPressed: () => _openShop(business, isOwner),
                                      icon: const Icon(Icons.storefront_rounded),
                                      label: Text(isOwner ? 'My shop' : 'Shop'),
                                    ),
                                    if (!isOwner && currentUserId != null)
                                      StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                                        stream: _pageFollowDoc(
                                          currentUserId,
                                          widget.businessId,
                                        ),
                                        builder: (context, followSnap) {
                                          final isFollowing =
                                              followSnap.data?.exists == true;
                                          return ElevatedButton.icon(
                                            onPressed: () async {
                                              if (isFollowing) {
                                                await _unfollowPage(
                                                  currentUserId,
                                                  widget.businessId,
                                                );
                                              } else {
                                                await _followPage(
                                                  currentUserId,
                                                  widget.businessId,
                                                );
                                              }
                                            },
                                            icon: Icon(
                                              isFollowing
                                                  ? Icons.favorite_rounded
                                                  : Icons.favorite_border_rounded,
                                            ),
                                            label: Text(
                                              isFollowing ? 'Following' : 'Follow',
                                            ),
                                          );
                                        },
                                      ),
                                    OutlinedButton.icon(
                                      onPressed: () {
                                        context.push(
                                          AppRoutes.pageFollowersPath(
                                            widget.businessId,
                                          ),
                                        );
                                      },
                                      icon: const Icon(Icons.people_outline_rounded),
                                      label: Text(tr('View followers')),
                                    ),
                                  ],
                                ),
                                if (category.toString().isNotEmpty ||
                                    phone.toString().isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  if (category.toString().isNotEmpty)
                                    Expanded(
                                      child: _buildInfoLine(
                                        icon: Icons.category_outlined,
                                        label: tr('Category'),
                                        value: category.toString(),
                                      ),
                                    ),
                                  if (category.toString().isNotEmpty &&
                                      phone.toString().isNotEmpty)
                                    const SizedBox(width: 12),
                                  if (phone.toString().isNotEmpty)
                                    Expanded(
                                      child: _buildInfoLine(
                                        icon: Icons.call_outlined,
                                        label: tr('Phone'),
                                        value: phone.toString(),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                            if (email.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              Center(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 360),
                                  child: _buildInfoLine(
                                    icon: Icons.email_outlined,
                                    label: tr('Email'),
                                    value: email,
                                  ),
                                ),
                              ),
                            ],
                            if (address.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              _buildInfoLine(
                                icon: Icons.place_outlined,
                                label: tr('Address'),
                                value: address,
                              ),
                            ],
                              ],
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildLocationCard(
                        business: business,
                        name: name.toString(),
                        address: address,
                        mapsLink: mapsLink,
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('posts')
                      .where('ownerId', isEqualTo: ownerId)
                      .snapshots(),
                  builder: (context, postsSnapshot) {
                    if (postsSnapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final docs = postsSnapshot.data?.docs ?? [];
                    final posts = docs
                        .map((d) => Post.fromFirestore(d))
                        .where((p) =>
                            p.businessId == widget.businessId ||
                            (p.businessId.isEmpty && p.businessName == name))
                        .toList()
                      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

                    if (posts.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.all(24),
                        child: Center(child: Text(tr('No posts yet'))),
                      );
                    }

                    final totalLikes = posts.fold<int>(
                        0, (total, p) => total + p.likeCount);
                    final avgLikes =
                        totalLikes / (posts.isEmpty ? 1 : posts.length);

                    return Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.star,
                                  color: Color(0xFFFFD700), size: 16),
                              const SizedBox(width: 4),
                              Text(
                                avgLikes.toStringAsFixed(1),
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                tr('avg likes'),
                                style: const TextStyle(color: AppColors.grey),
                              ),
                            ],
                          ),
                        ),
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(8),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 6,
                            mainAxisSpacing: 6,
                          ),
                          itemCount: posts.length,
                          itemBuilder: (context, index) {
                            final post = posts[index];
                            return InkWell(
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => PostDetailPage(post: post),
                                  ),
                                );
                              },
                              child: Container(
                                color: AppColors.lightGrey,
                                child: post.media.isNotEmpty &&
                                        !post.media.first.isVideo
                                    ? CachedNetworkImage(
                                        imageUrl: post.media.first.url,
                                        fit: BoxFit.cover,
                                      )
                                    : post.media.isNotEmpty &&
                                            post.media.first.isVideo
                                        ? FutureBuilder<Uint8List?>(
                                            future: _getVideoThumbnail(
                                                post.media.first.url),
                                            builder: (context, thumbSnap) {
                                              final bytes = thumbSnap.data;
                                              if (bytes == null) {
                                                return const Center(
                                                  child: Icon(
                                                    Icons.play_circle_fill,
                                                    color: Colors.white70,
                                                    size: 32,
                                                  ),
                                                );
                                              }
                                              return Stack(
                                                fit: StackFit.expand,
                                                children: [
                                                  Image.memory(bytes,
                                                      fit: BoxFit.cover),
                                                  const Center(
                                                    child: Icon(
                                                      Icons.play_circle_fill,
                                                      color: Colors.white70,
                                                      size: 32,
                                                    ),
                                                  ),
                                                ],
                                              );
                                            },
                                          )
                                        : const Icon(Icons.text_snippet_outlined),
                              ),
                            );
                          },
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildDesktopLayout({
    required Map<String, dynamic> business,
    required String name,
    required String? imageUrl,
    required String category,
    required String phone,
    required bool isVerified,
    required String ownerId,
    required String? currentUserId,
    required bool isOwner,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor = isDark ? const Color(0xFF151A24) : Colors.white;
    final address =
        (business['address'] ?? business['location'] ?? '').toString().trim();
    final mapsLink = (business['googleMapsLink'] ?? '').toString().trim();
    final description = (business['description'] ?? '').toString().trim();
    final email = (business['email'] ?? '').toString().trim();

    return StreamBuilder<QuerySnapshot>(
      stream: _pageFollowers(widget.businessId),
      builder: (context, followersSnap) {
        final followersCount = followersSnap.data?.docs.length ?? 0;
        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('posts')
              .where('ownerId', isEqualTo: ownerId)
              .snapshots(),
          builder: (context, postsSnapshot) {
            if (postsSnapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            final docs = postsSnapshot.data?.docs ?? [];
            final posts = docs
                .map((d) => Post.fromFirestore(d))
                .where((p) =>
                    p.businessId == widget.businessId ||
                    (p.businessId.isEmpty && p.businessName == name))
                .toList()
              ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

            final totalLikes =
                posts.fold<int>(0, (total, p) => total + p.likeCount);
            final avgLikes = posts.isEmpty ? 0.0 : totalLikes / posts.length;
            final mediaPosts = posts.where((p) => p.media.isNotEmpty).length;
            final videoPosts = posts
                .where((p) => p.media.any((item) => item.isVideo))
                .length;

            return SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1380),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            IconButton.filledTonal(
                              onPressed: _handleBackNavigation,
                              icon: const Icon(Icons.arrow_back_rounded),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              tr('Business profile'),
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: surfaceColor,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: isDark ? Colors.white10 : Colors.black12,
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              CircleAvatar(
                                radius: 46,
                                backgroundColor: AppColors.primary,
                                backgroundImage:
                                    imageUrl != null && imageUrl.isNotEmpty
                                        ? CachedNetworkImageProvider(imageUrl)
                                        : null,
                                child: imageUrl == null || imageUrl.isEmpty
                                    ? Text(
                                        name.isNotEmpty
                                            ? name.characters.first.toUpperCase()
                                            : 'P',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 24,
                                        ),
                                      )
                                    : null,
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Flexible(
                                          child: Text(
                                            name,
                                            textAlign: TextAlign.center,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .headlineSmall
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w800,
                                                ),
                                          ),
                                        ),
                                        if (isVerified)
                                          const Padding(
                                            padding: EdgeInsets.only(left: 8),
                                            child: Icon(
                                              Icons.verified_rounded,
                                              color: Colors.green,
                                            ),
                                          ),
                                      ],
                                    ),
                                    if (description.isNotEmpty) ...[
                                      const SizedBox(height: 10),
                                      Text(
                                        description,
                                        textAlign: TextAlign.center,
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: isDark ? Colors.white70 : Colors.black87,
                                          height: 1.35,
                                        ),
                                      ),
                                    ],
                                    const SizedBox(height: 14),
                                    Wrap(
                                      alignment: WrapAlignment.center,
                                      spacing: 10,
                                      runSpacing: 10,
                                      children: [
                                        if (phone.isNotEmpty)
                                          OutlinedButton.icon(
                                            onPressed: () => _dialPhone(context, phone),
                                            icon: const Icon(Icons.call_rounded),
                                            label: Text(tr('Call')),
                                          ),
                                        ElevatedButton.icon(
                                          onPressed: () => _openBusinessChat(ownerId),
                                          icon: const Icon(Icons.message_outlined),
                                          label: Text(isOwner ? 'Open inbox' : 'Message'),
                                        ),
                                        OutlinedButton.icon(
                                          onPressed: () => _openShop(business, isOwner),
                                          icon: const Icon(Icons.storefront_rounded),
                                          label: Text(isOwner ? 'My shop' : 'Shop'),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 16),
                              Container(
                                width: 260,
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? Colors.white.withValues(alpha: 0.03)
                                      : AppColors.primary.withValues(alpha: 0.05),
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      tr('Quick stats'),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 15,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    _buildInfoLine(
                                      icon: Icons.grid_view_rounded,
                                      label: tr('Posts'),
                                      value: posts.length.toString(),
                                    ),
                                    const SizedBox(height: 10),
                                    _buildInfoLine(
                                      icon: Icons.favorite_border_rounded,
                                      label: tr('Avg likes'),
                                      value: avgLikes.toStringAsFixed(1),
                                    ),
                                    const SizedBox(height: 10),
                                    _buildInfoLine(
                                      icon: Icons.play_circle_outline_rounded,
                                      label: tr('Videos'),
                                      value: videoPosts.toString(),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 10,
                              child: Column(
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _desktopMetricCard(
                                          title: tr('Total likes'),
                                          value: _formatCompactNumber(totalLikes),
                                          subtitle: 'Across ${posts.length} published posts',
                                          icon: Icons.favorite_border_rounded,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: _desktopMetricCard(
                                          title: tr('Media posts'),
                                          value: mediaPosts.toString(),
                                          subtitle: tr('Photos and videos combined'),
                                          icon: Icons.perm_media_rounded,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: _desktopMetricCard(
                                          title: tr('Videos'),
                                          value: videoPosts.toString(),
                                          subtitle: tr('Motion content on the page'),
                                          icon: Icons.play_circle_outline_rounded,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 16),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: surfaceColor,
                                      borderRadius: BorderRadius.circular(22),
                                      border: Border.all(
                                        color: isDark ? Colors.white10 : Colors.black12,
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    tr('Recent posts'),
                                                    style: const TextStyle(
                                                      fontSize: 18,
                                                      fontWeight: FontWeight.w800,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 4),
                                                  Text(
                                                    tr('A cleaner desktop gallery for this business page.'),
                                                    style: TextStyle(
                                                      color: isDark
                                                          ? Colors.white70
                                                          : AppColors.grey,
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            Text(
                                              '${posts.length} items',
                                              style: const TextStyle(
                                                color: AppColors.grey,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 14),
                                        if (posts.isEmpty)
                                          Container(
                                            width: double.infinity,
                                            padding: const EdgeInsets.all(28),
                                            decoration: BoxDecoration(
                                              color: isDark
                                                  ? Colors.white.withValues(alpha: 0.03)
                                                  : Colors.black.withValues(alpha: 0.02),
                                              borderRadius: BorderRadius.circular(16),
                                            ),
                                            child: Column(
                                              children: [
                                                const Icon(
                                                  Icons.photo_library_outlined,
                                                  color: AppColors.grey,
                                                  size: 32,
                                                ),
                                                const SizedBox(height: 10),
                                                Text(tr('No posts yet')),
                                              ],
                                            ),
                                          )
                                        else
                                          GridView.builder(
                                            shrinkWrap: true,
                                            physics: const NeverScrollableScrollPhysics(),
                                            itemCount: posts.length,
                                            gridDelegate:
                                                const SliverGridDelegateWithFixedCrossAxisCount(
                                              crossAxisCount: 3,
                                              crossAxisSpacing: 10,
                                              mainAxisSpacing: 10,
                                            ),
                                            itemBuilder: (context, index) {
                                              final post = posts[index];
                                              return InkWell(
                                                onTap: () {
                                                  Navigator.of(context).push(
                                                    MaterialPageRoute(
                                                      builder: (_) => PostDetailPage(post: post),
                                                    ),
                                                  );
                                                },
                                                borderRadius: BorderRadius.circular(16),
                                                child: Container(
                                                  decoration: BoxDecoration(
                                                    color: AppColors.lightGrey,
                                                    borderRadius: BorderRadius.circular(16),
                                                  ),
                                                  clipBehavior: Clip.antiAlias,
                                                  child: post.media.isNotEmpty &&
                                                          !post.media.first.isVideo
                                                      ? CachedNetworkImage(
                                                          imageUrl: post.media.first.url,
                                                          fit: BoxFit.cover,
                                                        )
                                                      : post.media.isNotEmpty &&
                                                              post.media.first.isVideo
                                                          ? FutureBuilder<Uint8List?>(
                                                              future: _getVideoThumbnail(
                                                                post.media.first.url,
                                                              ),
                                                              builder: (context, thumbSnap) {
                                                                final bytes = thumbSnap.data;
                                                                if (bytes == null) {
                                                                  return const Center(
                                                                    child: Icon(
                                                                      Icons.play_circle_fill,
                                                                      color: Colors.white70,
                                                                      size: 38,
                                                                    ),
                                                                  );
                                                                }
                                                                return Stack(
                                                                  fit: StackFit.expand,
                                                                  children: [
                                                                    Image.memory(
                                                                      bytes,
                                                                      fit: BoxFit.cover,
                                                                    ),
                                                                    const Center(
                                                                      child: Icon(
                                                                        Icons.play_circle_fill,
                                                                        color: Colors.white70,
                                                                        size: 38,
                                                                      ),
                                                                    ),
                                                                  ],
                                                                );
                                                              },
                                                            )
                                                          : const Center(
                                                              child: Icon(
                                                                Icons.text_snippet_outlined,
                                                              ),
                                                            ),
                                                ),
                                              );
                                            },
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 16),
                            SizedBox(
                              width: 340,
                              child: Column(
                                children: [
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: surfaceColor,
                                      borderRadius: BorderRadius.circular(22),
                                      border: Border.all(
                                        color: isDark ? Colors.white10 : Colors.black12,
                                      ),
                                    ),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Align(
                                            alignment: Alignment.center,
                                            child: Text(
                                              tr('About this page'),
                                              style: const TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 12),
                                          Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: [
                                            _StatPill(
                                              label: tr('Followers'),
                                              value: followersCount,
                                            ),
                                            if (!isOwner && currentUserId != null)
                                              StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                                                stream: _pageFollowDoc(
                                                  currentUserId,
                                                  widget.businessId,
                                                ),
                                                builder: (context, followSnap) {
                                                  final isFollowing =
                                                      followSnap.data?.exists == true;
                                                  return ElevatedButton.icon(
                                                    onPressed: () async {
                                                      if (isFollowing) {
                                                        await _unfollowPage(
                                                          currentUserId,
                                                          widget.businessId,
                                                        );
                                                      } else {
                                                        await _followPage(
                                                          currentUserId,
                                                          widget.businessId,
                                                        );
                                                      }
                                                    },
                                                    icon: Icon(
                                                      isFollowing
                                                          ? Icons.favorite_rounded
                                                          : Icons.favorite_border_rounded,
                                                    ),
                                                    label: Text(
                                                      isFollowing ? 'Following' : 'Follow page',
                                                    ),
                                                  );
                                                },
                                              ),
                                            OutlinedButton.icon(
                                              onPressed: () {
                                                context.push(
                                                  AppRoutes.pageFollowersPath(
                                                    widget.businessId,
                                                  ),
                                                );
                                              },
                                              icon: const Icon(Icons.people_outline_rounded),
                                              label: Text(tr('View followers')),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 12),
                                        if (category.isNotEmpty || phone.isNotEmpty) ...[
                                          Row(
                                            children: [
                                              if (category.isNotEmpty)
                                                Expanded(
                                                  child: _buildInfoLine(
                                                    icon: Icons.category_outlined,
                                                    label: tr('Category'),
                                                    value: category,
                                                  ),
                                                ),
                                              if (category.isNotEmpty && phone.isNotEmpty)
                                                const SizedBox(width: 12),
                                              if (phone.isNotEmpty)
                                                Expanded(
                                                  child: _buildInfoLine(
                                                    icon: Icons.call_outlined,
                                                    label: tr('Phone'),
                                                    value: phone,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ],
                                        if (email.isNotEmpty) ...[
                                          const SizedBox(height: 10),
                                          Center(
                                            child: ConstrainedBox(
                                              constraints:
                                                  const BoxConstraints(maxWidth: 320),
                                              child: _buildInfoLine(
                                                icon: Icons.email_outlined,
                                                label: tr('Email'),
                                                value: email,
                                              ),
                                            ),
                                          ),
                                        ],
                                        if (address.isNotEmpty) ...[
                                          const SizedBox(height: 10),
                                          _buildInfoLine(
                                            icon: Icons.place_outlined,
                                            label: tr('Address'),
                                            value: address,
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  _buildLocationCard(
                                    business: business,
                                    name: name,
                                    address: address,
                                    mapsLink: mapsLink,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildLocationCard({
    required Map<String, dynamic> business,
    required String name,
    required String address,
    required String mapsLink,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor = isDark ? const Color(0xFF151A24) : Colors.white;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isDark ? Colors.white10 : Colors.black12,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                tr('Location'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              if (mapsLink.isNotEmpty || address.isNotEmpty)
                TextButton.icon(
                  onPressed: () => _openBusinessLocation(business),
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: Text(tr('Open full map')),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            address.isEmpty ? 'Pin this page on the map.' : address,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isDark ? Colors.white70 : AppColors.grey,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: SizedBox(
              height: 220,
              child: FutureBuilder<LatLng?>(
                future: _getBusinessLocation(business),
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return Container(
                      color: isDark ? Colors.white10 : Colors.black12,
                      child: const Center(child: CircularProgressIndicator()),
                    );
                  }

                  final point = snap.data;
                  if (point == null) {
                    return Container(
                      color: isDark ? Colors.white10 : Colors.black12,
                      child: Center(
                        child: Text(
                          mapsLink.isNotEmpty || address.isNotEmpty
                              ? 'Location preview unavailable'
                              : 'No location added yet',
                          style: const TextStyle(
                            color: AppColors.grey,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    );
                  }

                  if (_supportsNativeGoogleMap) {
                    return gmaps.GoogleMap(
                      initialCameraPosition: gmaps.CameraPosition(
                        target: gmaps.LatLng(point.latitude, point.longitude),
                        zoom: 13.4,
                      ),
                      markers: {
                        gmaps.Marker(
                          markerId: gmaps.MarkerId(widget.businessId),
                          position: gmaps.LatLng(point.latitude, point.longitude),
                          infoWindow: gmaps.InfoWindow(title: name),
                        ),
                      },
                      mapType: gmaps.MapType.normal,
                      zoomControlsEnabled: false,
                      myLocationButtonEnabled: false,
                      mapToolbarEnabled: false,
                      compassEnabled: true,
                      trafficEnabled: false,
                      indoorViewEnabled: false,
                    );
                  }

                  return FlutterMap(
                    options: MapOptions(
                      initialCenter: point,
                      initialZoom: 13.4,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'businessfinder',
                      ),
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: point,
                            width: 120,
                            height: 72,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(999),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Colors.black26,
                                        blurRadius: 10,
                                        offset: Offset(0, 4),
                                      ),
                                    ],
                                  ),
                                  child: Text(
                                    name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.black87,
                                    ),
                                  ),
                                ),
                                const Icon(
                                  Icons.location_on_rounded,
                                  color: AppColors.primary,
                                  size: 30,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _desktopMetricCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF151A24) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark ? Colors.white10 : Colors.black12,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.primary),
          const SizedBox(height: 10),
          Text(
            value,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(
              color: isDark ? Colors.white70 : AppColors.grey,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoLine({
    required IconData icon,
    required String label,
    required String value,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: AppColors.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: isDark ? Colors.white70 : AppColors.grey,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _formatCompactNumber(int value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    }
    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(1)}K';
    }
    return value.toString();
  }

  void _openShop(Map<String, dynamic> business, bool isOwner) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CatalogPage(
        businessId: widget.businessId,
        businessName: (business['name'] ?? 'Shop').toString(),
        isOwner: isOwner,
        hasMomoCode: (business['momoCode'] ?? '').toString().trim().isNotEmpty,
      ),
    ));
  }

  Future<void> _openBusinessChat(String ownerId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (user.uid == ownerId) {
      if (!mounted) return;
      context.push(AppRoutes.chats);
      return;
    }

    final repo = ChatRepository();
    final chatId = await repo.createOrGetChat(
      businessId: widget.businessId,
      businessOwnerId: ownerId,
      clientId: user.uid,
    );
    if (!mounted) return;
    context.push(AppRoutes.chatDetailPath(chatId));
  }

  Future<void> _openBusinessLocation(Map<String, dynamic> business) async {
    final mapsLink = (business['googleMapsLink'] ?? '').toString().trim();
    final address =
        (business['address'] ?? business['location'] ?? '').toString().trim();

    Uri? uri;
    if (mapsLink.isNotEmpty) {
      uri = Uri.tryParse(mapsLink);
    } else if (address.isNotEmpty) {
      uri = Uri.parse(
        'https://www.openstreetmap.org/search?query=${Uri.encodeComponent(address)}',
      );
    }

    if (uri == null) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Could not open the map location.'))),
      );
    }
  }

  Future<LatLng?> _getBusinessLocation(Map<String, dynamic> business) {
    return _locationCache.putIfAbsent(
      widget.businessId,
      () => _resolveBusinessLocation(business),
    );
  }

  LatLng? _extractBusinessPoint(Map<String, dynamic> business) {
    double? parseNum(dynamic value) {
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '');
    }

    final directLat = parseNum(business['latitude']) ??
        parseNum(business['lat']) ??
        parseNum(business['locationLat']) ??
        parseNum(business['location_lat']);
    final directLng = parseNum(business['longitude']) ??
        parseNum(business['lng']) ??
        parseNum(business['locationLng']) ??
        parseNum(business['location_lng']) ??
        parseNum(business['lon']);
    if (directLat != null && directLng != null) {
      return LatLng(directLat, directLng);
    }

    final mapsLink = (business['googleMapsLink'] ?? '').toString().trim();
    if (mapsLink.isEmpty) return null;

    final uri = Uri.tryParse(mapsLink);
    if (uri != null) {
      final q = uri.queryParameters['q'] ?? uri.queryParameters['query'];
      if (q != null) {
        final parts = q.split(',');
        if (parts.length >= 2) {
          final lat = double.tryParse(parts[0].trim());
          final lng = double.tryParse(parts[1].trim());
          if (lat != null && lng != null) {
            return LatLng(lat, lng);
          }
        }
      }
    }

    final atMatch = RegExp(r'@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)')
        .firstMatch(mapsLink);
    if (atMatch != null) {
      final lat = double.tryParse(atMatch.group(1) ?? '');
      final lng = double.tryParse(atMatch.group(2) ?? '');
      if (lat != null && lng != null) {
        return LatLng(lat, lng);
      }
    }

    return null;
  }

  Future<LatLng?> _resolveBusinessLocation(Map<String, dynamic> business) async {
    final directPoint = _extractBusinessPoint(business);
    if (directPoint != null) return directPoint;

    final address =
        (business['address'] ?? business['location'] ?? '').toString().trim();
    final name = (business['name'] ?? '').toString().trim();
    final query = address.isNotEmpty
        ? address
        : name.isNotEmpty
            ? name
            : '';
    if (query.isEmpty) return null;

    try {
      final uri = Uri.https(
        'nominatim.openstreetmap.org',
        '/search',
        {
          'q': query,
          'format': 'jsonv2',
          'limit': '1',
        },
      );
      final client = HttpClient();
      final request = await client.getUrl(uri);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'businessfinder/1.0 (desktop-profile-map)',
      );
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      client.close();

      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(body);
      if (decoded is List && decoded.isNotEmpty) {
        final first = decoded.first;
        if (first is Map<String, dynamic>) {
          final lat = double.tryParse(first['lat']?.toString() ?? '');
          final lon = double.tryParse(first['lon']?.toString() ?? '');
          if (lat != null && lon != null) {
            return LatLng(lat, lon);
          }
        }
      }
    } catch (_) {
      // Ignore geocoding failures and fall back to placeholder UI.
    }

    return null;
  }

  Widget _circleIconButton({
    required IconData icon,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Opacity(
        opacity: onTap == null ? 0.4 : 1,
        child: CircleAvatar(
          radius: 18,
          backgroundColor: AppColors.lightGrey,
          child: Icon(icon, size: 18, color: AppColors.primary),
        ),
      ),
    );
  }

  Future<void> _followPage(String followerId, String pageId) async {
    final docId = '${followerId}_$pageId';
    await FirebaseFirestore.instance
        .collection('page_follows')
        .doc(docId)
        .set({
      'followerId': followerId,
      'pageId': pageId,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _unfollowPage(String followerId, String pageId) async {
    final docId = '${followerId}_$pageId';
    await FirebaseFirestore.instance
        .collection('page_follows')
        .doc(docId)
        .delete();
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> _pageFollowDoc(
      String followerId, String pageId) {
    final docId = '${followerId}_$pageId';
    return FirebaseFirestore.instance
        .collection('page_follows')
        .doc(docId)
        .snapshots();
  }

  Stream<QuerySnapshot> _pageFollowers(String pageId) {
    return FirebaseFirestore.instance
        .collection('page_follows')
        .where('pageId', isEqualTo: pageId)
        .snapshots();
  }

  Future<void> _dialPhone(BuildContext context, String phone) async {
    final trimmed = phone.trim();
    if (trimmed.isEmpty) return;
    final normalized = trimmed.replaceAll(RegExp(r'\s+'), '');
    final uri = Uri(scheme: 'tel', path: normalized);
    final ok = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Could not open dialer.'))),
      );
    }
  }

}

class _StatPill extends StatelessWidget {
  const _StatPill({
    required this.label,
    required this.value,
  });

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: isDark ? Colors.white12 : Colors.black12,
        ),
      ),
      child: Column(
        children: [
          Text(
            value.toString(),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              color: AppColors.grey,
            ),
          ),
        ],
      ),
    );
  }
}
