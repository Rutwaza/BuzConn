import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Which pages have a shop and which are verified, loaded once and kept
/// for 10 minutes. The feed uses it to show "🛍 Shop" and the ✓ badge
/// without one database read per post.
class PageIndex extends ChangeNotifier {
  PageIndex._();
  static final PageIndex instance = PageIndex._();

  Set<String> _shops = {};
  Set<String> _verified = {};
  DateTime? _loadedAt;
  bool _loading = false;

  bool hasShop(String businessId) =>
      businessId.isNotEmpty && _shops.contains(businessId);
  bool isVerified(String businessId) =>
      businessId.isNotEmpty && _verified.contains(businessId);

  Future<void> refresh({bool force = false}) async {
    if (_loading) return;
    if (!force &&
        _loadedAt != null &&
        DateTime.now().difference(_loadedAt!) < const Duration(minutes: 10)) {
      return;
    }
    _loading = true;
    try {
      final pages = FirebaseFirestore.instance.collection('businesses');
      final results = await Future.wait([
        pages.where('productCount', isGreaterThan: 0).limit(500).get(),
        pages.where('verified', isEqualTo: true).limit(500).get(),
      ]);
      _shops = results[0].docs.map((d) => d.id).toSet();
      _verified = results[1].docs.map((d) => d.id).toSet();
      _loadedAt = DateTime.now();
      notifyListeners();
    } catch (e) {
      debugPrint('PageIndex: $e');
    } finally {
      _loading = false;
    }
  }

  /// After the owner adds their first product, show it at once.
  void markShop(String businessId) {
    if (_shops.add(businessId)) notifyListeners();
  }
}
