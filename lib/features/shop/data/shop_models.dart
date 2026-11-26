import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

final _rwf = NumberFormat.decimalPattern('en_US');

/// "5,000 RWF"
String formatRwf(num amount) => '${_rwf.format(amount)} RWF';

class Product {
  Product({
    required this.id,
    required this.name,
    required this.price,
    this.description = '',
    this.imageUrl,
    this.inStock = true,
    this.soldCount = 0,
  });

  factory Product.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return Product(
      id: doc.id,
      name: (d['name'] ?? '').toString(),
      price: (d['price'] as num?)?.round() ?? 0,
      description: (d['description'] ?? '').toString(),
      imageUrl: d['imageUrl'] as String?,
      inStock: d['inStock'] != false,
      soldCount: (d['soldCount'] as num?)?.round() ?? 0,
    );
  }

  final String id;
  final String name;
  final int price; // whole RWF
  final String description;
  final String? imageUrl;
  final bool inStock;

  /// How many were sold (confirmed orders). Kept by the server.
  final int soldCount;
}

enum OrderStatus {
  pendingPayment('pending_payment', 'Waiting for payment'),
  paidClaimed('paid_claimed', 'Buyer says paid'),
  confirmed('confirmed', 'Paid ✓'),
  notReceived('not_received', 'Not received by shop'),
  ready('ready', 'Ready 📦'),
  delivered('delivered', 'Delivered ✓'),
  cancelled('cancelled', 'Cancelled');

  /// Where this order is on the buyer's tracking line (0..3), -1 = off it.
  int get step => switch (this) {
        OrderStatus.pendingPayment || OrderStatus.notReceived => 0,
        OrderStatus.paidClaimed => 1,
        OrderStatus.confirmed => 2,
        OrderStatus.ready => 3,
        OrderStatus.delivered => 4,
        OrderStatus.cancelled => -1,
      };

  const OrderStatus(this.value, this.label);
  final String value;
  final String label;

  static OrderStatus parse(String? v) =>
      OrderStatus.values.firstWhere((s) => s.value == v,
          orElse: () => OrderStatus.pendingPayment);
}

class OrderItem {
  OrderItem(
      {required this.name,
      required this.price,
      required this.qty,
      this.imageUrl});
  final String name;
  final int price;
  final int qty;
  final String? imageUrl;
}

class ShopOrder {
  ShopOrder({
    required this.id,
    required this.businessId,
    required this.businessName,
    required this.businessOwnerId,
    required this.buyerId,
    required this.items,
    required this.total,
    required this.status,
    required this.momoCode,
    this.momoName,
    this.txRef,
    this.createdAt,
  });

  factory ShopOrder.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    final items = (d['items'] as List? ?? [])
        .whereType<Map>()
        .map((m) => OrderItem(
              name: (m['name'] ?? '').toString(),
              price: (m['price'] as num?)?.round() ?? 0,
              qty: (m['qty'] as num?)?.round() ?? 1,
              imageUrl: m['imageUrl'] as String?,
            ))
        .toList();
    return ShopOrder(
      id: doc.id,
      businessId: (d['businessId'] ?? '').toString(),
      businessName: (d['businessName'] ?? 'Shop').toString(),
      businessOwnerId: (d['businessOwnerId'] ?? '').toString(),
      buyerId: (d['buyerId'] ?? '').toString(),
      items: items,
      total: (d['total'] as num?)?.round() ?? 0,
      status: OrderStatus.parse(d['status'] as String?),
      momoCode: (d['momoCode'] ?? '').toString(),
      momoName: d['momoName'] as String?,
      txRef: d['txRef'] as String?,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }

  final String id;
  final String businessId;
  final String businessName;
  final String businessOwnerId;
  final String buyerId;
  final List<OrderItem> items;
  final int total;
  final OrderStatus status;
  final String momoCode;
  final String? momoName;
  final String? txRef;
  final DateTime? createdAt;

  String get summary {
    if (items.isEmpty) return '';
    final first = '${items.first.qty} × ${items.first.name}';
    return items.length == 1 ? first : '$first + ${items.length - 1} more';
  }
}
