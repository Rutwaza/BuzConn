import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One controller per open chat. Riverpod creates it when the chat screen
/// opens and disposes it when the screen closes:
///
///   final controller = ref.watch(chatMessagesProvider(chatId));
///
/// What it fixes (Phase 2):
/// - Before, the screen opened a new Firestore listener on *every* rebuild and
///   downloaded the whole chat history each time.
/// - Now there is exactly one listener for the newest [pageSize] messages.
///   Scrolling up calls [loadMore], which widens the window by another page.
final chatMessagesProvider = ChangeNotifierProvider.autoDispose
    .family<ChatMessagesController, String>((ref, chatId) {
  return ChatMessagesController(chatId)..start();
});

class ChatMessagesController extends ChangeNotifier {
  ChatMessagesController(
    this.chatId, {
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  static const int pageSize = 30;

  final String chatId;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;
  Timestamp? _clearedAt;
  int _limit = pageSize;
  bool _disposed = false;

  List<QueryDocumentSnapshot<Map<String, dynamic>>> docs = const [];
  bool isLoading = true;
  bool isLoadingMore = false;
  bool hasMore = true;
  Object? error;

  /// Ghost messages are decoded once per message, not on every rebuild.
  final Map<String, String> _ghostTextCache = {};

  CollectionReference<Map<String, dynamic>> get _messages =>
      _firestore.collection('chats').doc(chatId).collection('messages');

  Future<void> start() async {
    await _readClearedAt();
    _listen();
  }

  Future<void> _readClearedAt() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    try {
      final chat = await _firestore.collection('chats').doc(chatId).get();
      final cleared = chat.data()?['clearedAt'];
      _clearedAt = cleared is Map && cleared[uid] is Timestamp
          ? cleared[uid] as Timestamp
          : null;
    } catch (_) {}
  }

  void _listen() {
    _sub?.cancel();
    Query<Map<String, dynamic>> query =
        _messages.orderBy('createdAt', descending: true);
    if (_clearedAt != null) {
      query = query.where('createdAt', isGreaterThan: _clearedAt);
    }
    // includeMetadataChanges: also tells us when a message we just sent is
    // confirmed by the server (clock icon -> tick).
    _sub = query.limit(_limit).snapshots(includeMetadataChanges: true).listen(
      (snapshot) {
        docs = snapshot.docs;
        hasMore = snapshot.docs.length >= _limit;
        isLoading = false;
        isLoadingMore = false;
        error = null;
        _notify();
      },
      onError: (Object e) {
        error = e;
        isLoading = false;
        isLoadingMore = false;
        _notify();
      },
    );
  }

  /// Load one more page of older messages (call when the user scrolls up).
  void loadMore() {
    if (!hasMore || isLoadingMore || isLoading) return;
    isLoadingMore = true;
    _limit += pageSize;
    _notify();
    _listen();
  }

  /// After "Clear chat": hide everything older than now for this user.
  Future<void> reloadAfterClear() async {
    await _readClearedAt();
    _limit = pageSize;
    _listen();
  }

  String ghostText(String messageId, String Function() decode) {
    return _ghostTextCache.putIfAbsent(messageId, decode);
  }

  /// All media/links/docs for the "shared" panel: a one-time read, not a
  /// second live listener on the whole history.
  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> loadSharedItems({
    int max = 500,
  }) async {
    Query<Map<String, dynamic>> query =
        _messages.orderBy('createdAt', descending: true);
    if (_clearedAt != null) {
      query = query.where('createdAt', isGreaterThan: _clearedAt);
    }
    final snap = await query.limit(max).get();
    return snap.docs;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    super.dispose();
  }
}
