import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/services/r2_storage_service.dart';
import 'shop_models.dart';

class ShopRepository {
  final _db = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> _products(String businessId) =>
      _db.collection('businesses').doc(businessId).collection('products');

  Stream<List<Product>> products(String businessId) => _products(businessId)
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((s) => s.docs.map(Product.fromDoc).toList());

  Future<void> saveProduct({
    required String businessId,
    String? productId,
    required String name,
    required int price,
    required String description,
    required bool inStock,
    Uint8List? newImage,
    String? currentImageUrl,
  }) async {
    final ref = productId == null
        ? _products(businessId).doc()
        : _products(businessId).doc(productId);
    String? imageUrl = currentImageUrl;
    if (newImage != null) {
      imageUrl = await R2StorageService.instance.uploadImage(
        bucket: 'post-images',
        path: 'products/${ref.id}_${DateTime.now().millisecondsSinceEpoch}.jpg',
        bytes: newImage,
      );
    }
    await ref.set({
      'name': name,
      'price': price,
      'description': description,
      'inStock': inStock,
      'imageUrl': imageUrl,
      'updatedAt': FieldValue.serverTimestamp(),
      if (productId == null) 'createdAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> deleteProduct(String businessId, String productId) =>
      _products(businessId).doc(productId).delete();

  /// Asks the server to make the order with the real prices.
  Future<({String orderId, int total})> createOrder({
    required String businessId,
    required Map<String, int> qtyByProductId,
    String? requestId,
  }) async {
    try {
      final r = await R2StorageService.instance.callFunction('createOrder', {
        'businessId': businessId,
        if (requestId != null) 'requestId': requestId,
        'items': [
          for (final e in qtyByProductId.entries)
            if (e.value > 0) {'productId': e.key, 'qty': e.value},
        ],
      });
      return (
        orderId: r['orderId'] as String,
        total: (r['total'] as num).round(),
      );
    } on HttpException catch (e) {
      throw ShopException(e.message);
    }
  }

  Stream<ShopOrder?> order(String orderId) => _db
      .collection('orders')
      .doc(orderId)
      .snapshots()
      .map((d) => d.exists ? ShopOrder.fromDoc(d) : null);

  /// Orders I made (as a buyer) or, with [asShop], orders to my shops.
  Stream<List<ShopOrder>> myOrders({bool asShop = false}) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return _db
        .collection('orders')
        .where(asShop ? 'businessOwnerId' : 'buyerId', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(50)
        .snapshots()
        .map((s) => s.docs.map(ShopOrder.fromDoc).toList());
  }

  Future<void> _set(String orderId, Map<String, Object?> data) => _db
      .collection('orders')
      .doc(orderId)
      .update({...data, 'updatedAt': FieldValue.serverTimestamp()});

  Future<void> buyerPaid(String orderId, {String? txRef}) => _set(orderId, {
        'status': OrderStatus.paidClaimed.value,
        'paidClaimedAt': FieldValue.serverTimestamp(),
        if (txRef != null && txRef.trim().isNotEmpty) 'txRef': txRef.trim(),
      });

  Future<void> buyerCancelled(String orderId) =>
      _set(orderId, {'status': OrderStatus.cancelled.value});

  Future<void> shopConfirmed(String orderId) => _set(orderId, {
        'status': OrderStatus.confirmed.value,
        'confirmedAt': FieldValue.serverTimestamp(),
      });

  Future<void> shopNotReceived(String orderId) =>
      _set(orderId, {'status': OrderStatus.notReceived.value});

  Future<void> shopReady(String orderId) => _set(orderId, {
        'status': OrderStatus.ready.value,
        'readyAt': FieldValue.serverTimestamp(),
      });

  Future<void> shopDelivered(String orderId) => _set(orderId, {
        'status': OrderStatus.delivered.value,
        'deliveredAt': FieldValue.serverTimestamp(),
      });

  /// Best sellers first (counted by the server), then the newest.
  Stream<List<Product>> popularProducts(String businessId, {int limit = 8}) =>
      products(businessId).map((list) {
        final inStock = list.where((p) => p.inStock).toList()
          ..sort((a, b) => b.soldCount.compareTo(a.soldCount));
        return inStock.take(limit).toList();
      });

  Future<Product?> product(String businessId, String productId) async {
    final d = await _products(businessId).doc(productId).get();
    return d.exists ? Product.fromDoc(d) : null;
  }
}

class ShopException implements Exception {
  const ShopException(this.message);
  final String message;
  @override
  String toString() => message;
}
