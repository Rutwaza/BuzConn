import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class NotificationReadService {
  NotificationReadService._();

  static Future<void> markAllRead() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final firestore = FirebaseFirestore.instance;
    final unread = await firestore
        .collection('notifications')
        .where('toUserId', isEqualTo: user.uid)
        .where('readAt', isEqualTo: null)
        .get();
    final timestamp = Timestamp.now();
    for (var start = 0; start < unread.docs.length; start += 450) {
      final batch = firestore.batch();
      for (final doc in unread.docs.skip(start).take(450)) {
        batch.update(doc.reference, {'readAt': timestamp});
      }
      await batch.commit();
    }
    await firestore.collection('users').doc(user.uid).set({
      'lastSeenNotificationsAt': timestamp,
    }, SetOptions(merge: true));
  }
}
