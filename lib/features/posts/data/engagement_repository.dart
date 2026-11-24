import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../../data/models/post_model.dart';

/// Likes and comments as their own documents (Phase 2).
///
/// Before: `posts/{id}.likes` and `posts/{id}.comments` were lists inside the
/// post. Every like rewrote the whole post, every phone watching it
/// re-downloaded it, and a popular post could hit Firestore's 1 MB limit.
///
/// Now:
///   posts/{postId}/likes/{uid}            one small doc per like
///   users/{uid}/liked_posts/{postId}      "what I liked" (to colour hearts)
///   posts/{postId}/comments/{commentId}   one doc per comment
///   posts/{postId}.likeCount / commentCount   kept up to date by Cloud
///                                         Functions (functions/social.js)
class LikeStore extends ValueNotifier<Set<String>> {
  LikeStore._() : super(<String>{}) {
    _auth.authStateChanges().listen((user) {
      value = <String>{};
      if (user != null) unawaited(_load(user.uid));
    });
  }

  static final LikeStore instance = LikeStore._();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  bool isLiked(String postId) => value.contains(postId);

  Future<void> _load(String uid) async {
    try {
      final snap = await _firestore
          .collection('users')
          .doc(uid)
          .collection('liked_posts')
          .orderBy('createdAt', descending: true)
          .limit(1000)
          .get();
      value = {...value, ...snap.docs.map((d) => d.id)};
    } catch (e) {
      debugPrint('Could not load liked posts: $e');
    }
  }

  /// Flips the like at once on screen, then writes in the background.
  /// Returns the new state (true = liked).
  Future<bool> toggle(String postId) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return false;
    final willLike = !isLiked(postId);
    value = willLike ? {...value, postId} : ({...value}..remove(postId));

    final likeRef = _firestore
        .collection('posts')
        .doc(postId)
        .collection('likes')
        .doc(uid);
    final mineRef = _firestore
        .collection('users')
        .doc(uid)
        .collection('liked_posts')
        .doc(postId);
    final batch = _firestore.batch();
    if (willLike) {
      final data = {'userId': uid, 'createdAt': FieldValue.serverTimestamp()};
      batch.set(likeRef, data);
      batch.set(mineRef, data);
    } else {
      batch.delete(likeRef);
      batch.delete(mineRef);
    }
    try {
      await batch.commit();
    } catch (e) {
      // Undo on screen if the server refused.
      value = willLike ? ({...value}..remove(postId)) : {...value, postId};
      rethrow;
    }
    return willLike;
  }
}

class CommentsRepository {
  CommentsRepository({FirebaseFirestore? firestore, FirebaseAuth? auth})
      : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  static const int maxLength = 2000;

  CollectionReference<Map<String, dynamic>> _comments(String postId) =>
      _firestore.collection('posts').doc(postId).collection('comments');

  /// Newest [limit] comments, oldest first (like a conversation).
  Stream<List<Comment>> watch(String postId, {int limit = 100}) {
    return _comments(postId)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => Comment.fromMap({...d.data(), 'id': d.id}))
            .toList()
            .reversed
            .toList());
  }

  Future<void> add(String postId, String content, {Comment? replyTo}) async {
    final user = _auth.currentUser;
    if (user == null) return;
    final text = content.trim();
    if (text.isEmpty || text.length > maxLength) return;

    var userName = user.displayName ?? 'User';
    String? userImageUrl = user.photoURL;
    try {
      final me = await _firestore
          .collection('users')
          .doc(user.uid)
          .get(const GetOptions(source: Source.serverAndCache));
      userName = (me.data()?['name'] ?? userName).toString();
      userImageUrl = (me.data()?['imageUrl'] as String?) ?? userImageUrl;
    } catch (_) {}

    await _comments(postId).add({
      'userId': user.uid,
      'userName': userName,
      'userImageUrl': userImageUrl,
      'content': text,
      'likes': <String>[],
      'createdAt': FieldValue.serverTimestamp(),
      'replyToUserId': replyTo?.userId,
      'replyToUserName': replyTo?.userName,
      'replyToCommentId': replyTo?.id,
    });
  }

  Future<void> edit(String postId, String commentId, String content) async {
    final text = content.trim();
    if (text.isEmpty || text.length > maxLength) return;
    await _comments(postId).doc(commentId).update({
      'content': text,
      'editedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> delete(String postId, String commentId) =>
      _comments(postId).doc(commentId).delete();

  Future<void> toggleLike(String postId, Comment comment) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    await _comments(postId).doc(comment.id).update({
      'likes': comment.likes.contains(uid)
          ? FieldValue.arrayRemove([uid])
          : FieldValue.arrayUnion([uid]),
    });
  }
}
