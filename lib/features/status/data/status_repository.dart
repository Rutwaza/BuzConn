import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/services/r2_storage_service.dart';
import '../../../core/services/video_compressor.dart';
import '../../moderation/moderation.dart';

/// One status (story). It disappears 24 hours after it was posted: the app
/// stops showing it at `expiresAt`, and the server deletes it within the hour
/// (functions/status.js -> cleanupExpiredStatuses).
class StatusItem {
  StatusItem({
    required this.id,
    required this.ownerId,
    required this.ownerName,
    required this.type,
    required this.createdAt,
    required this.expiresAt,
    this.ownerImageUrl,
    this.mediaUrl,
    this.text = '',
    this.bgColor = 0xFF3A6EA5,
    this.viewCount = 0,
    this.postId,
    this.postBy,
  });

  factory StatusItem.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return StatusItem(
      id: doc.id,
      ownerId: (d['ownerId'] ?? '').toString(),
      ownerName: (d['ownerName'] ?? 'User').toString(),
      ownerImageUrl: d['ownerImageUrl'] as String?,
      type: (d['type'] ?? 'text').toString(),
      mediaUrl: d['mediaUrl'] as String?,
      text: (d['text'] ?? '').toString(),
      bgColor: (d['bgColor'] as num?)?.toInt() ?? 0xFF3A6EA5,
      viewCount: (d['viewCount'] as num?)?.toInt() ?? 0,
      postId: d['postId'] as String?,
      postBy: d['postBy'] as String?,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      expiresAt: (d['expiresAt'] as Timestamp?)?.toDate() ??
          DateTime.now().add(const Duration(hours: 24)),
    );
  }

  final String id;
  final String ownerId;
  final String ownerName;
  final String? ownerImageUrl;
  final String type; // image | video | text
  final String? mediaUrl;
  final String text;
  final int bgColor;
  final int viewCount;

  /// Set when this status is a shared post ("View post" button).
  final String? postId;
  final String? postBy;
  final DateTime createdAt;
  final DateTime expiresAt;
}

/// All active statuses of one person, oldest first (the order to watch them).
class StatusGroup {
  StatusGroup(this.ownerId, this.items);
  final String ownerId;
  final List<StatusItem> items;
  String get name => items.first.ownerName;
  String? get imageUrl => items.first.ownerImageUrl;
  DateTime get latest => items.last.createdAt;
}

class StatusRepository {
  StatusRepository._();
  static final StatusRepository instance = StatusRepository._();

  final _db = FirebaseFirestore.instance;
  static const lifetime = Duration(hours: 24);

  /// Statuses I already watched in this session (for the grey ring).
  final Set<String> seen = {};

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  Future<List<String>> _followingIds() async {
    final uid = _uid;
    if (uid == null) return [];
    final snap = await _db
        .collection('user_follows')
        .where('followerId', isEqualTo: uid)
        .limit(500)
        .get();
    return snap.docs
        .map((d) => (d.data()['followingId'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toList();
  }

  /// My own statuses first, then the people I follow, newest first.
  Future<List<StatusGroup>> loadGroups() async {
    final uid = _uid;
    if (uid == null) return [];
    final owners = {uid, ...await _followingIds()}.toList();
    final now = Timestamp.now();
    final items = <StatusItem>[];
    for (var i = 0; i < owners.length; i += 30) {
      final chunk = owners.sublist(i, i + 30 > owners.length ? owners.length : i + 30);
      final snap = await _db
          .collection('statuses')
          .where('ownerId', whereIn: chunk)
          .where('expiresAt', isGreaterThan: now)
          .get();
      items.addAll(snap.docs.map(StatusItem.fromDoc));
    }
    final byOwner = <String, List<StatusItem>>{};
    for (final s in items) {
      if (BlockService.instance.isBlocked(s.ownerId)) continue;
      byOwner.putIfAbsent(s.ownerId, () => []).add(s);
    }
    final groups = byOwner.entries.map((e) {
      e.value.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return StatusGroup(e.key, e.value);
    }).toList()
      ..sort((a, b) {
        if (a.ownerId == uid) return -1;
        if (b.ownerId == uid) return 1;
        // Unwatched first, then newest.
        final aSeen = allSeen(a), bSeen = allSeen(b);
        if (aSeen != bSeen) return aSeen ? 1 : -1;
        return b.latest.compareTo(a.latest);
      });
    return groups;
  }

  bool allSeen(StatusGroup g) => g.items.every((s) => seen.contains(s.id));

  Future<void> markSeen(StatusItem s) async {
    if (seen.contains(s.id)) return;
    seen.add(s.id);
    final uid = _uid;
    if (uid == null || uid == s.ownerId) return;
    final me = FirebaseAuth.instance.currentUser!;
    try {
      await _db.collection('statuses').doc(s.id).collection('views').doc(uid).set({
        'viewerId': uid,
        'viewerName': me.displayName ?? 'User',
        'viewerImageUrl': me.photoURL,
        'viewedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // Already viewed (rules allow one view per person) or offline.
    }
  }

  Stream<List<Map<String, dynamic>>> viewers(String statusId) => _db
      .collection('statuses')
      .doc(statusId)
      .collection('views')
      .orderBy('viewedAt', descending: true)
      .limit(200)
      .snapshots()
      .map((s) => s.docs.map((d) => d.data()).toList());

  Future<void> delete(String statusId) =>
      _db.collection('statuses').doc(statusId).delete();

  /// Posts a status. [image] or [video] or only [text].
  Future<void> post({
    Uint8List? image,
    File? video,
    String text = '',
    int bgColor = 0xFF3A6EA5,
    void Function(double progress)? onProgress,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Sign in first.');
    final profile = (await _db.collection('users').doc(uid).get()).data() ?? {};
    final ref = _db.collection('statuses').doc();
    String? mediaUrl;
    var type = 'text';
    if (image != null) {
      type = 'image';
      mediaUrl = await R2StorageService.instance.uploadImage(
        bucket: 'post-images',
        path: 'status/${ref.id}.jpg',
        bytes: image,
        onProgress: onProgress,
      );
    } else if (video != null) {
      type = 'video';
      final small = await VideoCompressor.compress(video);
      mediaUrl = await R2StorageService.instance.uploadVideo(
        bucket: 'post-videos',
        path: 'status/${ref.id}.mp4',
        bytes: await small.readAsBytes(),
        onProgress: onProgress,
      );
    }
    if (type != 'text' && (mediaUrl == null || mediaUrl.isEmpty)) {
      throw StateError('Upload failed. Try again.');
    }
    await ref.set({
      'ownerId': uid,
      'ownerName': (profile['name'] ?? FirebaseAuth.instance.currentUser?.displayName ?? 'User').toString(),
      'ownerImageUrl': (profile['imageUrl'] as String?) ?? FirebaseAuth.instance.currentUser?.photoURL,
      'type': type,
      'mediaUrl': mediaUrl,
      'text': text.trim(),
      'bgColor': bgColor,
      'viewCount': 0,
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(DateTime.now().add(lifetime)),
    });
  }

  /// "Add to story" from a post's share menu: the post's photo (or video
  /// cover) with its caption, and a "View post" button for viewers.
  Future<void> sharePost({
    required String postId,
    required String postBy,
    required String caption,
    String? imageUrl,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Sign in first.');
    final profile = (await _db.collection('users').doc(uid).get()).data() ?? {};
    final text = caption.trim().length > 200
        ? '${caption.trim().substring(0, 197)}…'
        : caption.trim();
    await _db.collection('statuses').add({
      'ownerId': uid,
      'ownerName': (profile['name'] ??
              FirebaseAuth.instance.currentUser?.displayName ??
              'User')
          .toString(),
      'ownerImageUrl': (profile['imageUrl'] as String?) ??
          FirebaseAuth.instance.currentUser?.photoURL,
      'type': imageUrl == null ? 'text' : 'image',
      'mediaUrl': imageUrl,
      'text': imageUrl == null ? '📮 $postBy\n\n$text' : text,
      'bgColor': 0xFF3A6EA5,
      'viewCount': 0,
      'postId': postId,
      'postBy': postBy,
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(DateTime.now().add(lifetime)),
    });
  }
}
