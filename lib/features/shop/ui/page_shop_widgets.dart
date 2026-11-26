import 'package:businessfinder/core/widgets/emoji_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../../core/i18n/tr.dart';
import '../../../core/theme/colors.dart';
import '../data/shop_models.dart';
import '../data/shop_repository.dart';
import 'catalog_page.dart';

/// "Popular in this shop": best sellers first, as small cards in a row.
/// Shows nothing if the page has no products.
class PopularProductsStrip extends StatelessWidget {
  const PopularProductsStrip({
    super.key,
    required this.businessId,
    required this.businessName,
    required this.ownerId,
  });

  final String businessId;
  final String businessName;
  final String ownerId;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Product>>(
      stream: ShopRepository().popularProducts(businessId),
      builder: (context, snap) {
        final products = snap.data ?? const <Product>[];
        if (products.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Text('🔥 ', style: TextStyle(fontSize: 16)),
                Text(tr('Popular in this shop'),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w800)),
                const Spacer(),
                TextButton(
                  onPressed: () => openShop(context,
                      businessId: businessId,
                      businessName: businessName,
                      ownerId: ownerId),
                  child: Text(tr('See all')),
                ),
              ]),
              const SizedBox(height: 6),
              SizedBox(
                height: 176,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: products.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (context, i) => _MiniProduct(
                    product: products[i],
                    onTap: () => openShop(context,
                        businessId: businessId,
                        businessName: businessName,
                        ownerId: ownerId,
                        productId: products[i].id),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MiniProduct extends StatelessWidget {
  const _MiniProduct({required this.product, required this.onTap});
  final Product product;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = product;
    return SizedBox(
      width: 128,
      child: Material(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 108,
                child: p.imageUrl == null
                    ? const ColoredBox(
                        color: AppColors.mist,
                        child: Icon(Icons.shopping_bag_rounded,
                            size: 34, color: AppColors.primaryLight))
                    : CachedNetworkImage(
                        imageUrl: p.imageUrl!,
                        fit: BoxFit.cover,
                        memCacheWidth: 300,
                        fadeInDuration: const Duration(milliseconds: 220),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                child: Text(p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 13)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
                child: Text(formatRwf(p.price),
                    style: const TextStyle(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w800,
                        fontSize: 12.5)),
              ),
              if (p.soldCount > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 1, 8, 0),
                  child: Text('${p.soldCount} ${tr('sold')}',
                      style:
                          const TextStyle(color: AppColors.grey, fontSize: 11)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stars + average + "Write a review" + the latest reviews.
class PageReviewsSection extends StatelessWidget {
  const PageReviewsSection({
    super.key,
    required this.businessId,
    required this.ownerId,
    required this.ratingAvg,
    required this.ratingCount,
  });

  final String businessId;
  final String ownerId;
  final double ratingAvg;
  final int ratingCount;

  CollectionReference<Map<String, dynamic>> get _reviews =>
      FirebaseFirestore.instance
          .collection('businesses')
          .doc(businessId)
          .collection('reviews');

  @override
  Widget build(BuildContext context) {
    final me = FirebaseAuth.instance.currentUser?.uid;
    final canReview = me != null && me != ownerId;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(tr('Reviews'),
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(width: 10),
            if (ratingCount > 0) ...[
              StarRow(rating: ratingAvg),
              const SizedBox(width: 6),
              Text('${ratingAvg.toStringAsFixed(1)} · $ratingCount',
                  style: const TextStyle(
                      color: AppColors.grey, fontWeight: FontWeight.w600)),
            ],
            const Spacer(),
            if (canReview)
              TextButton.icon(
                onPressed: () => _write(context, me),
                icon: const Icon(Icons.rate_review_outlined, size: 18),
                label: Text(tr('Write a review')),
              ),
          ]),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _reviews
                .orderBy('updatedAt', descending: true)
                .limit(5)
                .snapshots(),
            builder: (context, snap) {
              final docs = snap.data?.docs ?? const [];
              if (docs.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    canReview
                        ? tr('No reviews yet. Be the first to rate this page ⭐')
                        : tr('No reviews yet.'),
                    style: const TextStyle(color: AppColors.grey),
                  ),
                );
              }
              return Column(
                children: [
                  for (final d in docs)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        backgroundImage:
                            (d.data()['userImageUrl'] ?? '').toString().isEmpty
                                ? null
                                : CachedNetworkImageProvider(
                                    d.data()['userImageUrl'].toString()),
                        child:
                            (d.data()['userImageUrl'] ?? '').toString().isEmpty
                                ? const Icon(Icons.person)
                                : null,
                      ),
                      title: Row(children: [
                        Flexible(
                          child: Text(
                              (d.data()['userName'] ?? 'Someone').toString(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ),
                        const SizedBox(width: 8),
                        StarRow(
                            rating:
                                ((d.data()['rating'] as num?) ?? 0).toDouble(),
                            size: 14),
                      ]),
                      subtitle: (d.data()['text'] ?? '').toString().isEmpty
                          ? null
                          : Text(d.data()['text'].toString()),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _write(BuildContext context, String uid) async {
    final existing = await _reviews.doc(uid).get();
    if (!context.mounted) return;
    var rating = ((existing.data()?['rating'] as num?) ?? 5).round();
    final text = TextEditingController(
        text: (existing.data()?['text'] ?? '').toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(tr('Rate this page')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 1; i <= 5; i++)
                    IconButton(
                      onPressed: () => setLocal(() => rating = i),
                      icon: Icon(
                        i <= rating
                            ? Icons.star_rounded
                            : Icons.star_outline_rounded,
                        color: const Color(0xFFFFB400),
                        size: 34,
                      ),
                    ),
                ],
              ),
              TextField(
                controller: text,
                maxLength: 500,
                maxLines: 3,
                decoration: InputDecoration(
                  suffixIcon: EmojiButton(controller: text),
                  hintText: tr('What was good? What could be better?'),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(tr('Cancel'))),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(tr('Post review'))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final user = FirebaseAuth.instance.currentUser;
    final profile =
        (await FirebaseFirestore.instance.collection('users').doc(uid).get())
                .data() ??
            {};
    await _reviews.doc(uid).set({
      'rating': rating,
      'text': text.text.trim(),
      'userName': (profile['name'] ?? user?.displayName ?? 'User').toString(),
      'userImageUrl': (profile['imageUrl'] ?? user?.photoURL ?? '').toString(),
      if (!existing.exists) 'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }
}

class StarRow extends StatelessWidget {
  const StarRow({super.key, required this.rating, this.size = 16});
  final double rating;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          Icon(
            rating >= i
                ? Icons.star_rounded
                : rating >= i - 0.5
                    ? Icons.star_half_rounded
                    : Icons.star_outline_rounded,
            size: size,
            color: const Color(0xFFFFB400),
          ),
      ],
    );
  }
}
