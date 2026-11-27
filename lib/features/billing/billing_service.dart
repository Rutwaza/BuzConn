import '../../core/services/r2_storage_service.dart';

/// What people pay Duhuze for (functions/billing.js):
///  - `page_slot`: one more page (the first page is free).
///  - `boost`: show a post in For You as "Sponsored" for some days.
class BillingService {
  BillingService._();
  static final instance = BillingService._();

  Future<Map<String, dynamic>> _call(String name, Map<String, Object?> data) =>
      R2StorageService.instance.callFunction(name, data);

  Future<BillingInfo> info() async => BillingInfo(await _call('billingInfo', {}));

  /// Returns the server answer: {paymentId, status: pending|not_ready, kind, url, amount}.
  Future<Map<String, dynamic>> start({
    required String item,
    String? postId,
    String? packageId,
    String? phone,
    String? network,
  }) =>
      _call('startPurchase', {
        'item': item,
        if (postId != null) 'postId': postId,
        if (packageId != null) 'packageId': packageId,
        if (phone != null && phone.isNotEmpty) 'phone': phone,
        if (network != null) 'network': network,
      });

  // Pages (functions/pages.js).
  Future<Map<String, dynamic>> createPage(Map<String, Object?> page) =>
      _call('createPage', page);
  Future<Map<String, dynamic>> restorePage(String pageId) =>
      _call('restorePage', {'pageId': pageId});
  Future<Map<String, dynamic>> team(Map<String, Object?> data) =>
      _call('pageTeam', data);

  // Admin panel -> Payments.
  Future<Map<String, dynamic>> admin(Map<String, Object?> data) =>
      _call('adminBilling', data);
}

class BillingInfo {
  BillingInfo(this.raw);
  final Map<String, dynamic> raw;

  bool get ready => raw['ready'] == true;
  int get pageSlotPrice => (raw['pageSlotPrice'] as num?)?.toInt() ?? 0;

  /// What the next extra page costs this person (the 2nd page can have its
  /// own price, set in Admin -> Payments).
  int get nextPagePrice =>
      (raw['nextPagePrice'] as num?)?.toInt() ?? pageSlotPrice;
  PageSlots get pages =>
      PageSlots(Map<String, dynamic>.from(raw['pages'] as Map? ?? {}));
  List<BoostPackage> get boostPackages => (raw['boostPackages'] as List? ?? [])
      .map((e) => BoostPackage(Map<String, dynamic>.from(e as Map)))
      .toList();
}

class PageSlots {
  PageSlots(this.raw);
  final Map<String, dynamic> raw;
  int _i(String k) => (raw[k] as num?)?.toInt() ?? 0;
  int get free => _i('free');
  int get bought => _i('bought');
  int get total => _i('total');
  int get used => _i('used');
  bool get canCreate => raw['canCreate'] == true;
}

class BoostPackage {
  BoostPackage(this.raw);
  final Map<String, dynamic> raw;
  String get id => raw['id'].toString();
  int get days => (raw['days'] as num?)?.toInt() ?? 0;
  int get price => (raw['price'] as num?)?.toInt() ?? 0;
}

/// 5000 -> "5,000 RWF"
String rwf(num v) {
  final s = v.round().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return '$b RWF';
}
