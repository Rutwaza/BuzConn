import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/theme/colors.dart';
import '../data/shop_models.dart';
import '../data/shop_repository.dart';
import 'checkout_sheet.dart';
import 'orders_page.dart';

/// A business's shop: products in a grid. Buyers pick quantities and pay
/// with MoMo; the owner adds, edits and removes products.
class CatalogPage extends StatefulWidget {
  const CatalogPage({
    super.key,
    required this.businessId,
    required this.businessName,
    required this.isOwner,
    this.hasMomoCode = false,
  });

  final String businessId;
  final String businessName;
  final bool isOwner;
  final bool hasMomoCode;

  @override
  State<CatalogPage> createState() => _CatalogPageState();
}

class _CatalogPageState extends State<CatalogPage> {
  final _repo = ShopRepository();
  final Map<String, int> _cart = {};

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
            tooltip: 'Orders',
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
              label: const Text('Add product'),
            )
          : null,
      body: StreamBuilder<List<Product>>(
        stream: _repo.products(widget.businessId),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final products = snap.data!;
          final total = _total(products);
          return Column(
            children: [
              if (widget.isOwner && !widget.hasMomoCode)
                const MaterialBanner(
                  content: Text(
                      'Add your MoMo Pay code in Edit page so customers can pay you.'),
                  leading: Icon(Icons.info_outline_rounded,
                      color: AppColors.warning),
                  actions: [SizedBox.shrink()],
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
                            product: p,
                            qty: _cart[p.id] ?? 0,
                            isOwner: widget.isOwner,
                            onAdd: () => _change(p, 1),
                            onRemove: () => _change(p, -1),
                            onEdit: () => _edit(p),
                          );
                        },
                      ),
              ),
              if (!widget.isOwner && total > 0)
                SafeArea(
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
                ),
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
  });

  final Product product;
  final int qty;
  final bool isOwner;
  final VoidCallback onAdd;
  final VoidCallback onRemove;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final p = product;
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: isOwner ? onEdit : (p.inStock ? onAdd : null),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  p.imageUrl != null
                      ? CachedNetworkImage(
                          imageUrl: p.imageUrl!, fit: BoxFit.cover)
                      : Container(
                          color: AppColors.mist,
                          child: const Icon(Icons.shopping_bag_rounded,
                              size: 42, color: AppColors.primaryLight),
                        ),
                  if (!p.inStock)
                    Container(
                      color: Colors.black45,
                      alignment: Alignment.center,
                      child: const Text('Out of stock',
                          style: TextStyle(
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
                      label: const Text('Edit'),
                    )
                  : qty == 0
                      ? TextButton.icon(
                          onPressed: p.inStock ? onAdd : null,
                          icon: const Icon(Icons.add_shopping_cart_rounded,
                              size: 18),
                          label: const Text('Add'),
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
  XFile? _image;
  bool _saving = false;

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
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    try {
      await ShopRepository().saveProduct(
        businessId: widget.businessId,
        productId: widget.product?.id,
        name: _name.text.trim(),
        price: int.parse(_price.text.replaceAll(RegExp(r'[^0-9]'), '')),
        description: _desc.text.trim(),
        inStock: _inStock,
        newImage: _image == null ? null : await _image!.readAsBytes(),
        currentImageUrl: widget.product?.imageUrl,
      );
      nav.pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not save: $e')));
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
              GestureDetector(
                onTap: () async {
                  final img = await ImagePicker().pickImage(
                      source: ImageSource.gallery,
                      maxWidth: 1280,
                      imageQuality: 82);
                  if (img != null) setState(() => _image = img);
                },
                child: Container(
                  height: 150,
                  decoration: BoxDecoration(
                    color: AppColors.mist,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: _image != null
                      ? const Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.check_circle_rounded,
                              color: AppColors.success, size: 36),
                          Text('Photo chosen'),
                        ])
                      : p?.imageUrl != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(14),
                              child: CachedNetworkImage(
                                  imageUrl: p!.imageUrl!,
                                  fit: BoxFit.cover,
                                  width: double.infinity),
                            )
                          : const Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                  Icon(Icons.add_a_photo_rounded,
                                      color: AppColors.primary, size: 34),
                                  Text('Add a photo'),
                                ]),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _name,
                maxLength: 80,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'Enter a name' : null,
              ),
              TextFormField(
                controller: _price,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Price', suffixText: 'RWF'),
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
                decoration:
                    const InputDecoration(labelText: 'Description (optional)'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _inStock,
                onChanged: (v) => setState(() => _inStock = v),
                title: const Text('In stock'),
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
                    label: const Text('Delete'),
                  ),
                const Spacer(),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Save'),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
