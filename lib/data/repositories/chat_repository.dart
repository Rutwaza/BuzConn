import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ChatRepository {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  User? get currentUser => _auth.currentUser;

  Stream<QuerySnapshot> userChatsStream(String uid) {
    return _firestore
        .collection('chats')
        .where('participants', arrayContains: uid)
        .snapshots();
  }

  Future<String> createOrGetChat({
    required String businessId,
    required String businessOwnerId,
    required String clientId,
  }) async {
    final chatId = _chatIdFor(clientId, businessOwnerId);
    final docRef = _firestore.collection('chats').doc(chatId);
    final businessSnap =
        await _firestore.collection('businesses').doc(businessId).get();
    final business = businessSnap.data() ?? {};
    final businessName = business['name'] ?? 'Business';
    final businessImageUrl = business['imageUrl'];

    final clientSnap =
        await _firestore.collection('users').doc(clientId).get();
    final client = clientSnap.data() ?? {};
    final clientName = client['name'] ?? 'Client';
    final clientImageUrl = client['imageUrl'];

    await docRef.set({
      'participants': [clientId, businessOwnerId],
      'clientId': clientId,
      'clientName': clientName,
      'clientImageUrl': clientImageUrl,
      'businessOwnerId': businessOwnerId,
      'businessId': businessId,
      'businessName': businessName,
      'businessImageUrl': businessImageUrl,
      'chatType': 'business',
      'lastReadAt': {
        clientId: FieldValue.serverTimestamp(),
        businessOwnerId: FieldValue.serverTimestamp(),
      },
      'updatedAt': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    return chatId;
  }

  Future<String> createOrGetDirectChat({
    required String userAId,
    required String userBId,
  }) async {
    final chatId = _chatIdFor(userAId, userBId);
    final docRef = _firestore.collection('chats').doc(chatId);

    final userASnap = await _firestore.collection('users').doc(userAId).get();
    final userA = userASnap.data() ?? {};
    final userAName = userA['name'] ?? 'User';
    final userAImageUrl = userA['imageUrl'];

    final userBSnap = await _firestore.collection('users').doc(userBId).get();
    final userB = userBSnap.data() ?? {};
    final userBName = userB['name'] ?? 'User';
    final userBImageUrl = userB['imageUrl'];

    await docRef.set({
      'participants': [userAId, userBId],
      'chatType': 'direct',
      'userAId': userAId,
      'userAName': userAName,
      'userAImageUrl': userAImageUrl,
      'userBId': userBId,
      'userBName': userBName,
      'userBImageUrl': userBImageUrl,
      'lastReadAt': {
        userAId: FieldValue.serverTimestamp(),
        userBId: FieldValue.serverTimestamp(),
      },
      'updatedAt': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    return chatId;
  }

  Stream<QuerySnapshot> messagesStream(String chatId) {
    return _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  Future<void> sendMessage({
    required String chatId,
    required String senderId,
    required String text,
    String? mediaUrl,
    String? mediaType,
    Map<String, dynamic>? replyTo,
  }) async {
    final messageRef = _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc();
    final senderSnap = await _firestore.collection('users').doc(senderId).get();
    final sender = senderSnap.data() ?? {};
    final senderName = sender['name'] ?? 'User';
    final senderAvatar = sender['imageUrl'];
    await messageRef.set({
      'id': messageRef.id,
      'senderId': senderId,
      'senderName': senderName,
      'senderAvatar': senderAvatar,
      'text': text,
      'mediaUrl': mediaUrl,
      'mediaType': mediaType,
      'replyTo': replyTo,
      'createdAt': FieldValue.serverTimestamp(),
    });

    await _firestore.collection('chats').doc(chatId).update({
      'lastMessage': mediaUrl != null ? '[media]' : text,
      'lastMessageAt': FieldValue.serverTimestamp(),
      'lastMessageSenderId': senderId,
      'updatedAt': FieldValue.serverTimestamp(),
    });

    await _createMessageNotifications(
      chatId: chatId,
      senderId: senderId,
      senderName: senderName,
      senderAvatar: senderAvatar,
      previewText: mediaUrl != null ? '[media]' : text,
    );
  }

  Future<void> _createMessageNotifications({
    required String chatId,
    required String senderId,
    required String senderName,
    String? senderAvatar,
    required String previewText,
  }) async {
    final chatSnap = await _firestore.collection('chats').doc(chatId).get();
    final chatData = chatSnap.data() ?? {};
    final participants = (chatData['participants'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList();
    for (final uid in participants) {
      if (uid == senderId) continue;
      await _firestore.collection('notifications').add({
        'toUserId': uid,
        'fromUserId': senderId,
        'fromUserName': senderName,
        'fromUserImageUrl': senderAvatar,
        'type': 'message',
        'chatId': chatId,
        'preview': previewText,
        'readAt': null,
        'hidden': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
  }

  Future<void> setLastRead({
    required String chatId,
    required String userId,
  }) async {
    await _firestore.collection('chats').doc(chatId).update({
      'lastReadAt.$userId': FieldValue.serverTimestamp(),
    });
  }

  Future<void> editMessage({
    required String chatId,
    required String messageId,
    required String text,
  }) async {
    await _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId)
        .update({
      'text': text,
      'editedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> deleteMessage({
    required String chatId,
    required String messageId,
  }) async {
    await _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId)
        .update({
      'text': '',
      'mediaUrl': null,
      'mediaType': null,
      'deleted': true,
      'deletedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> setUserLastSeen(String userId) async {
    await _firestore.collection('users').doc(userId).update({
      'lastSeen': FieldValue.serverTimestamp(),
    });
  }

  String _chatIdFor(String a, String b) {
    final ordered = [a, b]..sort();
    return '${ordered[0]}_${ordered[1]}';
  }
}
