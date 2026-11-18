import 'dart:async';

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

    final clientSnap = await _firestore.collection('users').doc(clientId).get();
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
    String? mediaName,
    int? mediaSize,
    Map<String, dynamic>? replyTo,
    bool isGhost = false,
    String? ghostCipherText,
    String? ghostNonce,
  }) async {
    final chatRef = _firestore.collection('chats').doc(chatId);
    final messageRef =
        _firestore.collection('chats').doc(chatId).collection('messages').doc();
    var senderName = _auth.currentUser?.displayName ?? 'User';
    String? senderAvatar = _auth.currentUser?.photoURL;
    var isRequest = false;
    await _firestore.runTransaction((transaction) async {
      final chatSnap = await transaction.get(chatRef);
      final chat = chatSnap.data() ?? <String, dynamic>{};
      final participants = (chat['participants'] as List? ?? [])
          .map((id) => id.toString())
          .toList();
      final status = (chat['requestStatus'] ?? 'none').toString();
      final requesterId = chat['requesterId']?.toString();
      final chatUpdates = <String, dynamic>{
        'lastMessage': mediaUrl != null
            ? '[media]'
            : isGhost
                ? 'Ghost message'
                : text,
        'lastMessageAt': FieldValue.serverTimestamp(),
        'lastMessageSenderId': senderId,
        'updatedAt': FieldValue.serverTimestamp(),
      };
      if (status == 'pending' && requesterId != senderId) {
        throw StateError('This message request is waiting for approval.');
      }
      if (status == 'rejected') {
        throw StateError('This message request was declined.');
      }

      if (chat['chatType'] == 'direct') {
        final isUserA = chat['userAId'] == senderId;
        senderName = (isUserA ? chat['userAName'] : chat['userBName'])
                ?.toString() ??
            senderName;
        senderAvatar = (isUserA ? chat['userAImageUrl'] : chat['userBImageUrl'])
            as String?;
      } else if (chat['businessOwnerId'] == senderId) {
        senderName = (chat['businessName'] ?? senderName).toString();
        senderAvatar = chat['businessImageUrl'] as String?;
      } else {
        senderName = (chat['clientName'] ?? senderName).toString();
        senderAvatar = chat['clientImageUrl'] as String?;
      }

      isRequest = status == 'pending' && requesterId == senderId;
      if (chat['chatType'] == 'direct' && status == 'none') {
        if (chat['lastMessageAt'] == null) {
          final recipientId = participants.firstWhere(
            (id) => id != senderId,
            orElse: () => '',
          );
          if (recipientId.isNotEmpty) {
            isRequest = true;
            chatUpdates.addAll({
              'requestStatus': 'pending',
              'requesterId': senderId,
              'requestRecipientId': recipientId,
            });
          }
        }
      }
      transaction.set(messageRef, {
        'id': messageRef.id,
        'senderId': senderId,
        'senderName': senderName,
        'senderAvatar': senderAvatar,
        'text': text,
        'isGhost': isGhost,
        'ghostCipherText': ghostCipherText,
        'ghostNonce': ghostNonce,
        'mediaUrl': mediaUrl,
        'mediaType': mediaType,
        'mediaName': mediaName,
        'mediaSize': mediaSize,
        'replyTo': replyTo,
        'createdAt': FieldValue.serverTimestamp(),
      });
      transaction.update(chatRef, chatUpdates);
    });

    if (!isGhost || isRequest) {
      unawaited(
        _createMessageNotifications(
          chatId: chatId,
          senderId: senderId,
          senderName: senderName,
          senderAvatar: senderAvatar,
          previewText: mediaUrl != null ? '[media]' : text,
          type: isRequest ? 'message_request' : 'message',
        ).catchError((_) {}),
      );
    }
  }

  Future<void> _createMessageNotifications({
    required String chatId,
    required String senderId,
    required String senderName,
    String? senderAvatar,
    required String previewText,
    String type = 'message',
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
        'type': type,
        'chatId': chatId,
        'preview': previewText,
        'readAt': null,
        'hidden': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
  }

  Future<void> respondToMessageRequest({
    required String chatId,
    required String userId,
    required bool accept,
  }) async {
    final ref = _firestore.collection('chats').doc(chatId);
    await _firestore.runTransaction((transaction) async {
      final snapshot = await transaction.get(ref);
      final data = snapshot.data() ?? {};
      if (data['requestRecipientId'] != userId ||
          data['requestStatus'] != 'pending') {
        throw StateError('This message request is no longer available.');
      }
      transaction.update(ref, {
        'requestStatus': accept ? 'accepted' : 'rejected',
        'requestRespondedAt': FieldValue.serverTimestamp(),
        if (!accept) 'hiddenFor': FieldValue.arrayUnion([userId]),
      });
    });
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

  Future<void> hardDeleteMessage({
    required String chatId,
    required String messageId,
  }) async {
    final chatRef = _firestore.collection('chats').doc(chatId);
    final messagesRef = chatRef.collection('messages');
    await messagesRef.doc(messageId).delete();

    final latestSnap =
        await messagesRef.orderBy('createdAt', descending: true).limit(1).get();

    if (latestSnap.docs.isEmpty) {
      await chatRef.update({
        'lastMessage': '',
        'lastMessageAt': null,
        'lastMessageSenderId': null,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return;
    }

    final latest = latestSnap.docs.first.data();
    await chatRef.update({
      'lastMessage': latest['mediaUrl'] != null
          ? '[media]'
          : (latest['text'] ?? '').toString(),
      'lastMessageAt': latest['createdAt'],
      'lastMessageSenderId': latest['senderId'],
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> clearChatMessages(String chatId) async {
    final messagesRef =
        _firestore.collection('chats').doc(chatId).collection('messages');
    while (true) {
      final snap = await messagesRef.limit(200).get();
      if (snap.docs.isEmpty) break;
      final batch = _firestore.batch();
      for (final doc in snap.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();
    }
    await _firestore.collection('chats').doc(chatId).update({
      'lastMessage': '',
      'lastMessageAt': null,
      'lastMessageSenderId': null,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  String _chatIdFor(String a, String b) {
    final ordered = [a, b]..sort();
    return '${ordered[0]}_${ordered[1]}';
  }
}
