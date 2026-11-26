import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Which pages have a shop and which are verified, loaded once and kept
/// for 10 minutes. The feed uses it to show "🛍 Shop" and the ✓ badge
/// without one database read per post.
class PageIndex extends ChangeNotifier {
  PageIndex._();
  static final PageIndex instance = PageIndex._();

  Set<String> _shops = {};
  Set<String> _verified = {};
  Set<String> _suspendedPages = {};
  Set<String> _suspendedUsers = {};
  Set<String> _verifiedUsers = {};
  // Pages I own or am a team admin of (I can boost their posts).
  Set<String> _managed = {};
  DateTime? _loadedAt;
  bool _loading = false;

  bool hasShop(String businessId) =>
      businessId.isNotEmpty && _shops.contains(businessId);
  bool isVerified(String businessId) =>
      businessId.isNotEmpty && _verified.contains(businessId);

  bool isUserVerified(String uid) => _verifiedUsers.contains(uid);

  /// I own this page or I'm a team admin of it.
  bool managesPage(String businessId) =>
      businessId.isNotEmpty && _managed.contains(businessId);

  /// ✓ next to a post's author: the page if it's a page post, else the person.
  bool postAuthorVerified(String businessId, String ownerId) =>
      businessId.isNotEmpty ? isVerified(businessId) : isUserVerified(ownerId);

  /// Posts of suspended pages/people are not shown (Admin panel).
  bool hidesPost(String businessId, String ownerId) =>
      (businessId.isNotEmpty && _suspendedPages.contains(businessId)) ||
      _suspendedUsers.contains(ownerId);

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
      final users = FirebaseFirestore.instance.collection('users');
      final results = await Future.wait([
        pages.where('productCount', isGreaterThan: 0).limit(500).get(),
        pages.where('verified', isEqualTo: true).limit(500).get(),
        pages.where('suspended', isEqualTo: true).limit(500).get(),
        users.where('suspended', isEqualTo: true).limit(500).get(),
        users.where('verified', isEqualTo: true).limit(1000).get(),
      ]);
      _shops = results[0].docs.map((d) => d.id).toSet();
      _verified = results[1].docs.map((d) => d.id).toSet();
      _suspendedPages = results[2].docs.map((d) => d.id).toSet();
      _suspendedUsers = results[3].docs.map((d) => d.id).toSet();
      _verifiedUsers = results[4].docs.map((d) => d.id).toSet();
      _shops.removeAll(_suspendedPages);
      final me = FirebaseAuth.instance.currentUser?.uid;
      if (me != null) {
        final mine = await Future.wait([
          pages.where('ownerId', isEqualTo: me).get(),
          pages.where('teamIds', arrayContains: me).get(),
        ]);
        _managed = {
          ...mine[0].docs.map((d) => d.id),
          ...mine[1].docs
              .where((d) => (d.data()['team'] as Map?)?[me] == 'admin')
              .map((d) => d.id),
        };
      }
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
