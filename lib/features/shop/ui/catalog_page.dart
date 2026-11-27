import 'package:businessfinder/core/widgets/emoji_picker.dart';
import 'package:businessfinder/core/widgets/app_toast.dart';
import 'package:businessfinder/core/services/media_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:businessfinder/core/widgets/desktop_width.dart';
import 'package:businessfinder/core/i18n/tr.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/theme/colors.dart';
import '../data/shop_models.dart';
import '../data/shop_repository.dart';
import 'checkout_sheet.dart';
import 'orders_page.dart';
import '../logic/page_index.dart';

/// A business's shop: products in a grid. Buyers pick quantities and pay
/// with MoMo; the owner adds, edits and removes products.
class CatalogPage extends StatefulWidget {
  const CatalogPage({
    super.key,
    required this.businessId,
    required this.businessName,
    required this.isOwner,
    this.hasMomoCode = false,
    this.highlightProductId,
  });

  final String businessId;
  final String businessName;
  final bool isOwner;
  final bool hasMomoCode;

  /// Opened from a post's "Buy" button: this product starts in the cart
  /// and is outlined.
  final String? highlightProductId;

  @override
  State<CatalogPage> createState() => _CatalogPageState();
}

class _CatalogPageState extends State<CatalogPage> {
  final _repo = ShopRepository();
  late final Stream<List<Product>> _productsStream =
      _repo.products(widget.businessId);
  final Map<String, int> _cart = {};

  @override
  void initState() {
    super.initState();
    final id = widget.highlightProductId;
    if (id != null && !widget.isOwner) _cart[id] = 1;
  }

  int _total(List<Product> products) =>
      products.fold(0, (sum, p) => sum + p.price * (_cart[p.id] ?? 0));

  void _change(Product p, int delta) {
    setState(() {
      final next = ((_cart[p.id] ?? 0) + delta).clamp(0, 99);
      if (next == 0) {
        _cart.remove(p.id);
      } else {
        _cart[p.id] = next;
      }
    });
  }

  Future<void> _edit([Product? p]) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ProductEditor(businessId: widget.businessId, product: p),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.businessName} · Shop'),
        actions: [
          IconButton(
            tooltip: tr('Orders'),
            icon: const Icon(Icons.receipt_long_rounded),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => OrdersPage(startOnShopTab: widget.isOwner),
            )),
          ),
        ],
      ),
      floatingActionButton: widget.isOwner
          ? FloatingActionButton.extended(
              onPressed: () => _edit(),
              icon: const Icon(Icons.add_rounded),
              label: Text(tr('Add product')),
            )
          : null,
      body: StreamBuilder<List<Product>>(
        stream: _productsStream,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final products = snap.data!;
          final total = _total(products);
          return Column(
            children: [
              if (widget.isOwner && !widget.hasMomoCode)
                MaterialBanner(
                  content: Text(tr(
                      'Add your MoMo Pay code in Edit page so customers can pay you.')),
                  leading: const Icon(Icons.info_outline_rounded,
                      color: AppColors.warning),
                  actions: const [SizedBox.shrink()],
                ),
              Expanded(
                child: products.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            widget.isOwner
                                ? 'Your shop is empty. Tap "Add product" to start selling.'
                                : 'This shop has no products yet.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: AppColors.grey),
                          ),
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 100),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 220,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 0.68,
                        ),
                        itemCount: products.length,
                        itemBuilder: (_, i) {
                          final p = products[i];
                          return _ProductTile(
                            highlighted: p.id == widget.highlightProductId,
                            product: p,
                            qty: _cart[p.id] ?? 0,
                            isOwner: widget.isOwner,
                            onAdd: () => _change(p, 1),
                            onRemove: () => _change(p, -1),
                            onEdit: () => _edit(p),
                            onOpen: () => showProductGallery(
                              context,
                              product: p,
                              isOwner: widget.isOwner,
                              qty: () => _cart[p.id] ?? 0,
                              onAdd: () => _change(p, 1),
                              onRemove: () => _change(p, -1),
                              onEdit: () => _edit(p),
                            ),
                          );
                        },
                      ),
              ),
              if (!widget.isOwner && total > 0)
                DesktopWidth(
                    maxWidth: 520,
                    child: SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                        child: SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: FilledButton.icon(
                            icon: const Icon(Icons.payments_rounded),
                            label: Text('Pay ${formatRwf(total)} with MoMo'),
                            onPressed: () async {
                              final done = await showCheckout(
                                context,
                                businessId: widget.businessId,
                                qtyByProductId: Map.of(_cart),
                              );
                              if (done && mounted) setState(_cart.clear);
                            },
                          ),
                        ),
                      ),
                    )),
            ],
          );
        },
      ),
    );
  }
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({
    required this.product,
    required this.qty,
    required this.isOwner,
    required this.onAdd,
    required this.onRemove,
    required this.onEdit,
    required this.onOpen,
    this.highlighted = false,
  });

  final bool highlighted;
  final Product product;
  final int qty;
  final bool isOwner;
  final VoidCallback onAdd;
  final VoidCallback onRemove;
  final VoidCallback onEdit;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final p = product;
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: highlighted
            ? const BorderSide(color: AppColors.primary, width: 2.5)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: isOwner ? onEdit : onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  p.gallery.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: p.gallery.first,
                          fit: BoxFit.cover,
                          memCacheWidth: 500,
                          fadeInDuration: const Duration(milliseconds: 220))
                      : Container(
                          color: AppColors.mist,
                          child: const Icon(Icons.shopping_bag_rounded,
                              size: 42, color: AppColors.primaryLight),
                        ),
                  // Several photos: the little "stack" mark, like a carousel post.
                  if (p.gallery.length > 1)
                    Positioned(
                      right: 8,
                      top: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.collections_rounded,
                              size: 12, color: Colors.white),
                          const SizedBox(width: 4),
                          Text('${p.gallery.length}',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800)),
                        ]),
                      ),
                    ),
                  if (!p.inStock)
                    Container(
                      color: Colors.black45,
                      alignment: Alignment.center,
                      child: Text(tr('Out of stock'),
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700)),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(formatRwf(p.price),
                      style: const TextStyle(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w800)),
                ],
              ),
            ),
            SizedBox(
              height: 40,
              child: isOwner
                  ? TextButton.icon(
                      onPressed: onEdit,
                      icon: const Icon(Icons.edit_rounded, size: 18),
                      label: Text(tr('Edit')),
                    )
                  : qty == 0
                      ? TextButton.icon(
                          onPressed: p.inStock ? onAdd : null,
                          icon: const Icon(Icons.add_shopping_cart_rounded,
                              size: 18),
                          label: Text(tr('Add')),
                        )
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            IconButton(
                                onPressed: onRemove,
                                icon: const Icon(
                                    Icons.remove_circle_outline_rounded)),
                            Text('$qty',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800)),
                            IconButton(
                                onPressed: onAdd,
                                icon: const Icon(Icons.add_circle_rounded,
                                    color: AppColors.primary)),
                          ],
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProductEditor extends StatefulWidget {
  const _ProductEditor({required this.businessId, this.product});
  final String businessId;
  final Product? product;

  @override
  State<_ProductEditor> createState() => _ProductEditorState();
}

class _ProductEditorState extends State<_ProductEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.product?.name ?? '');
  late final _price = TextEditingController(
      text: widget.product == null ? '' : '${widget.product!.price}');
  late final _desc =
      TextEditingController(text: widget.product?.description ?? '');
  late bool _inStock = widget.product?.inStock ?? true;
  // The photos in order (the first one is the cover): saved ones have a
  // `url`, new ones picked now have `bytes`.
  late final List<ProductPhoto> _photos = [
    for (final u in widget.product?.gallery ?? const <String>[])
      ProductPhoto(url: u),
  ];
  bool _saving = false;

  Future<void> _addPhotos() async {
    final room = maxProductPhotos - _photos.length;
    if (room <= 0) return;
    final picked = await MediaPicker.pickMultiImage(maxWidth: 1280);
    if (picked.isEmpty) return;
    final added = <ProductPhoto>[];
    for (final f in picked.take(room)) {
      added.add(ProductPhoto(bytes: await f.readAsBytes()));
    }
    if (mounted) setState(() => _photos.addAll(added));
  }

  void _removeAt(int i) => setState(() => _photos.removeAt(i));

  /// Make photo [i] the cover (the first one).
  void _makeCover(int i) => setState(() => _photos.insert(0, _photos.removeAt(i)));

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final nav = Navigator.of(context);
    try {
      await ShopRepository().saveProduct(
        businessId: widget.businessId,
        productId: widget.product?.id,
        name: _name.text.trim(),
        price: int.parse(_price.text.replaceAll(RegExp(r'[^0-9]'), '')),
        description: _desc.text.trim(),
        inStock: _inStock,
        photos: _photos,
      );
      PageIndex.instance.markShop(widget.businessId);
      nav.pop();
    } catch (e) {
      if (mounted) showToast(context, 'Could not save: $e');
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    return Padding(
      padding: EdgeInsets.only(
          left: 20,
          right: 20,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20),
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(p == null ? 'New product' : 'Edit product',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 14),
              _PhotoStrip(
                photos: _photos,
                onAdd: _saving ? null : _addPhotos,
                onRemove: _removeAt,
                onCover: _makeCover,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _name,
                maxLength: 80,
                decoration: InputDecoration(labelText: tr('Name')),
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'Enter a name' : null,
              ),
              TextFormField(
                controller: _price,
                keyboardType: TextInputType.number,
                decoration:
                    InputDecoration(labelText: tr('Price'), suffixText: 'RWF'),
                validator: (v) {
                  final n =
                      int.tryParse((v ?? '').replaceAll(RegExp(r'[^0-9]'), ''));
                  if (n == null || n <= 0) return 'Enter a price';
                  if (n > 10000000) return 'Too high';
                  return null;
                },
              ),
              TextFormField(
                controller: _desc,
                maxLines: 3,
                maxLength: 500,
                decoration: InputDecoration(
                  labelText: tr('Description (optional)'),
                  suffixIcon: EmojiButton(controller: _desc),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _inStock,
                onChanged: (v) => setState(() => _inStock = v),
                title: Text(tr('In stock')),
              ),
              const SizedBox(height: 8),
              Row(children: [
                if (p != null)
                  TextButton.icon(
                    style:
                        TextButton.styleFrom(foregroundColor: AppColors.error),
                    onPressed: _saving
                        ? null
                        : () async {
                            final nav = Navigator.of(context);
                            await ShopRepository()
                                .deleteProduct(widget.businessId, p.id);
                            nav.pop();
                          },
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: Text(tr('Delete')),
                  ),
                const Spacer(),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(tr('Save')),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens a page's shop from anywhere (feed "Shop"/"Buy" buttons, menu).
Future<void> openShop(
  BuildContext context, {
  required String businessId,
  required String businessName,
  required String ownerId,
  String? productId,
}) {
  final me = FirebaseAuth.instance.currentUser?.uid;
  return Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => CatalogPage(
      businessId: businessId,
      businessName: businessName,
      isOwner: me != null && me == ownerId,
      hasMomoCode: true, // the server checks it when ordering
      highlightProductId: productId,
    ),
  ));
}

/// Up to 4 photos of a product: tap "+" to add, a cross to remove, tap a
/// photo to make it the cover. The first photo is the cover.
class _PhotoStrip extends StatelessWidget {
  const _PhotoStrip({
    required this.photos,
    required this.onAdd,
    required this.onRemove,
    required this.onCover,
  });

  final List<ProductPhoto> photos;
  final VoidCallback? onAdd;
  final void Function(int) onRemove;
  final void Function(int) onCover;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    Widget tile(int i) {
      final p = photos[i];
      return Padding(
        padding: const EdgeInsets.only(right: 10),
        child: GestureDetector(
          onTap: i == 0 ? null : () => onCover(i),
          child: SizedBox(
            width: 92,
            height: 92,
            child: Stack(fit: StackFit.expand, children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: p.bytes != null
                    ? Image.memory(p.bytes!, fit: BoxFit.cover)
                    : CachedNetworkImage(
                        imageUrl: p.url!,
                        fit: BoxFit.cover,
                        memCacheWidth: 300,
                      ),
              ),
              if (i == 0)
                Positioned(
                  left: 6,
                  bottom: 6,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(tr('Cover'),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w800)),
                  ),
                ),
              Positioned(
                right: 4,
                top: 4,
                child: InkWell(
                  onTap: () => onRemove(i),
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: const BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    child:
                        const Icon(Icons.close_rounded, size: 14, color: Colors.white),
                  ),
                ),
              ),
            ]),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 92,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (var i = 0; i < photos.length; i++) tile(i),
              if (photos.length < maxProductPhotos)
                GestureDetector(
                  onTap: onAdd,
                  child: Container(
                    width: 92,
                    height: 92,
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white10 : AppColors.mist,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.add_a_photo_rounded,
                            color: AppColors.primary, size: 26),
                        const SizedBox(height: 4),
                        Text(
                          photos.isEmpty ? tr('Add photos') : tr('Add more'),
                          style: const TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '${photos.length}/$maxProductPhotos ${tr('photos')} · ${tr('tap a photo to make it the cover')}',
          style: const TextStyle(fontSize: 11.5, color: AppColors.grey),
        ),
      ],
    );
  }
}

/// A product, big: swipe through all its photos (up to 4), see the price and
/// description, add to the cart. Opened by tapping a product in a shop.
Future<void> showProductGallery(
  BuildContext context, {
  required Product product,
  required bool isOwner,
  required int Function() qty,
  required VoidCallback onAdd,
  required VoidCallback onRemove,
  required VoidCallback onEdit,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (_) => _ProductGallery(
      product: product,
      isOwner: isOwner,
      qty: qty,
      onAdd: onAdd,
      onRemove: onRemove,
      onEdit: onEdit,
    ),
  );
}

class _ProductGallery extends StatefulWidget {
  const _ProductGallery({
    required this.product,
    required this.isOwner,
    required this.qty,
    required this.onAdd,
    required this.onRemove,
    required this.onEdit,
  });

  final Product product;
  final bool isOwner;
  final int Function() qty;
  final VoidCallback onAdd;
  final VoidCallback onRemove;
  final VoidCallback onEdit;

  @override
  State<_ProductGallery> createState() => _ProductGalleryState();
}

class _ProductGalleryState extends State<_ProductGallery> {
  final _page = PageController();
  int _i = 0;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  void _go(int to) {
    final n = widget.product.gallery.length;
    if (to < 0 || to >= n) return;
    _page.animateToPage(to,
        duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final photos = p.gallery;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final q = widget.qty();
    return Dialog(
      backgroundColor: isDark ? const Color(0xFF151A24) : Colors.white,
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: Stack(fit: StackFit.expand, children: [
                  if (photos.isEmpty)
                    const ColoredBox(
                      color: AppColors.mist,
                      child: Icon(Icons.shopping_bag_rounded,
                          size: 70, color: AppColors.primaryLight),
                    )
                  else
                    PageView.builder(
                      controller: _page,
                      itemCount: photos.length,
                      onPageChanged: (v) => setState(() => _i = v),
                      itemBuilder: (_, i) => InteractiveViewer(
                        minScale: 1,
                        maxScale: 4,
                        child: CachedNetworkImage(
                          imageUrl: photos[i],
                          fit: BoxFit.cover,
                          fadeInDuration: const Duration(milliseconds: 200),
                        ),
                      ),
                    ),
                  if (photos.length > 1) ...[
                    // 1/4 counter, like a carousel post.
                    Positioned(
                      right: 12,
                      top: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text('${_i + 1}/${photos.length}',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                    if (_i > 0)
                      Positioned(
                        left: 6,
                        top: 0,
                        bottom: 0,
                        child: _Arrow(Icons.chevron_left_rounded, () => _go(_i - 1)),
                      ),
                    if (_i < photos.length - 1)
                      Positioned(
                        right: 6,
                        top: 0,
                        bottom: 0,
                        child:
                            _Arrow(Icons.chevron_right_rounded, () => _go(_i + 1)),
                      ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 10,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (var d = 0; d < photos.length; d++)
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              margin: const EdgeInsets.symmetric(horizontal: 3),
                              width: d == _i ? 18 : 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: d == _i ? Colors.white : Colors.white54,
                                borderRadius: BorderRadius.circular(99),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  Positioned(
                    left: 8,
                    top: 8,
                    child: IconButton.filledTonal(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.name,
                        style: const TextStyle(
                            fontSize: 19, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text(formatRwf(p.price),
                        style: const TextStyle(
                            color: AppColors.primary,
                            fontSize: 17,
                            fontWeight: FontWeight.w800)),
                    if (p.soldCount > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text('${p.soldCount} ${tr('sold')}',
                            style: const TextStyle(
                                fontSize: 12, color: AppColors.grey)),
                      ),
                    if (p.description.trim().isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(p.description.trim(),
                          style: const TextStyle(height: 1.35)),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
                child: widget.isOwner
                    ? FilledButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          widget.onEdit();
                        },
                        icon: const Icon(Icons.edit_rounded, size: 18),
                        label: Text(tr('Edit')),
                      )
                    : !p.inStock
                        ? Center(
                            child: Text(tr('Out of stock'),
                                style: const TextStyle(
                                    color: AppColors.grey,
                                    fontWeight: FontWeight.w700)),
                          )
                        : q == 0
                            ? FilledButton.icon(
                                onPressed: () {
                                  widget.onAdd();
                                  setState(() {});
                                },
                                icon: const Icon(Icons.add_shopping_cart_rounded,
                                    size: 18),
                                label: Text(tr('Add to cart')),
                                style: FilledButton.styleFrom(
                                    minimumSize: const Size.fromHeight(46)),
                              )
                            : Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  IconButton(
                                    onPressed: () {
                                      widget.onRemove();
                                      setState(() {});
                                    },
                                    icon: const Icon(
                                        Icons.remove_circle_outline_rounded,
                                        size: 30),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 14),
                                    child: Text('$q',
                                        style: const TextStyle(
                                            fontSize: 20,
                                            fontWeight: FontWeight.w800)),
                                  ),
                                  IconButton(
                                    onPressed: () {
                                      widget.onAdd();
                                      setState(() {});
                                    },
                                    icon: const Icon(Icons.add_circle_rounded,
                                        size: 30, color: AppColors.primary),
                                  ),
                                ],
                              ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow(this.icon, this.onTap);
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Center(
        child: Material(
          color: Colors.black45,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(icon, color: Colors.white, size: 26),
            ),
          ),
        ),
      );
}
