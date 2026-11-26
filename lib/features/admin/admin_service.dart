import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../core/services/r2_storage_service.dart';

/// Who may open the Admin panel. The real checks happen on the server
/// (functions/admin.js) and in firestore.rules; this only decides what the
/// app shows.
enum StaffRole { none, moderator, admin }

class AdminService {
  AdminService._();
  static final AdminService instance = AdminService._();

  // Temporary owner fallback, same as the server, until set-admin.js has run.
  static const _ownerEmails = {'nelsonjembe99@gmail.com'};

  Future<StaffRole> role({bool refresh = false}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return StaffRole.none;
    final token = await user.getIdTokenResult(refresh);
    final claims = token.claims ?? const {};
    if (claims['admin'] == true) return StaffRole.admin;
    if (user.emailVerified &&
        _ownerEmails.contains(user.email?.toLowerCase())) {
      return StaffRole.admin;
    }
    if (claims['moderator'] == true) return StaffRole.moderator;
    return StaffRole.none;
  }

  Future<Map<String, dynamic>> _call(String name, Map<String, Object?> data) =>
      R2StorageService.instance.callFunction(name, data);

  Future<Map<String, dynamic>> stats() => _call('adminStats', {});

  /// Verified badge on a business page.
  Future<void> setVerified(String businessId, bool verified) => _call(
      'adminSetVerified', {'businessId': businessId, 'verified': verified});

  Future<void> setPageSuspended(String businessId, bool suspended,
          {String note = ''}) =>
      _call('adminSetPageSuspended',
          {'businessId': businessId, 'suspended': suspended, 'note': note});

  Future<void> setUserVerified(String uid, bool verified) =>
      _call('adminSetUserVerified', {'uid': uid, 'verified': verified});

  Future<void> warnUser(String uid, String message) =>
      _call('adminWarnUser', {'uid': uid, 'message': message});

  Future<Map<String, dynamic>> userDetails(String uid) =>
      _call('adminUserDetails', {'uid': uid});

  Future<void> reviewVerification(String requestId, bool approve,
          {String note = ''}) =>
      _call('adminReviewVerification',
          {'requestId': requestId, 'approve': approve, 'note': note});

  Future<Map<String, dynamic>> broadcast(String message) =>
      _call('adminBroadcast', {'message': message});

  Future<void> resolveReport(String reportId, String action,
          {String note = ''}) =>
      _call('adminResolveReport',
          {'reportId': reportId, 'action': action, 'note': note});

  Future<void> setSuspended(String uid, bool suspended, {String note = ''}) =>
      _call('adminSetUserSuspended',
          {'uid': uid, 'suspended': suspended, 'note': note});

  Future<Map<String, dynamic>> setModerator(String email, bool enabled) =>
      _call('adminSetRole',
          {'email': email, 'role': enabled ? 'moderator' : 'none'});

  Stream<QuerySnapshot<Map<String, dynamic>>> reports({required bool open}) =>
      FirebaseFirestore.instance
          .collection('reports')
          .where('status', whereIn: open ? ['open'] : ['dismissed', 'actioned'])
          .orderBy('createdAt', descending: true)
          .limit(100)
          .snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> staff() =>
      FirebaseFirestore.instance.collection('staff').snapshots();

  /// Users whose name/username contains [term] (server-made searchKeywords).
  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> searchUsers(
      String term) async {
    final t = term.trim().toLowerCase();
    if (t.length < 2) return [];
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .where('searchKeywords', arrayContains: t)
        .limit(30)
        .get();
    return snap.docs;
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
      suspendedUsers() async {
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .where('suspended', isEqualTo: true)
        .limit(100)
        .get();
    return snap.docs;
  }
}
