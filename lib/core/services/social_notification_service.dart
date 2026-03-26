import 'package:cloud_firestore/cloud_firestore.dart';

class SocialNotificationService {
  SocialNotificationService._();

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static Future<void> createFollowNotification({
    required String followerId,
    required String followingId,
  }) async {
    if (followerId.isEmpty ||
        followingId.isEmpty ||
        followerId == followingId) {
      return;
    }

    final followerSnap = await _firestore.collection('users').doc(followerId).get();
    final followerData = followerSnap.data() ?? <String, dynamic>{};
    final followerName = (followerData['name'] ?? 'User').toString();
    final followerImage = (followerData['imageUrl'] ?? '').toString().trim();

    await _firestore.collection('notifications').add({
      'toUserId': followingId,
      'fromUserId': followerId,
      'fromUserName': followerName,
      'fromUserImageUrl': followerImage.isEmpty ? null : followerImage,
      'type': 'follow',
      'createdAt': FieldValue.serverTimestamp(),
      'readAt': null,
      'hidden': false,
    });
  }
}
