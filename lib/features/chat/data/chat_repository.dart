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
    Map<String, dynamic>? extra,
    String? messageId,
  }) async {
    final chatRef = _firestore.collection('chats').doc(chatId);
    final messageRef = _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId);
    var senderName = _auth.currentUser?.displayName ?? 'User';
    String? senderAvatar = _auth.currentUser?.photoURL;
    // Phase 2 speed fix: no transaction. A transaction must ask the server
    // first, so the message only appeared after a round trip (the "slow
    // send"). Now we read the chat from the phone's cache (it is already
    // open on screen) and write with a batch. Firestore shows a batch write in
    // the message list immediately and uploads it in the background.
    // The Firestore rules still decide whether the write is allowed.
    final chat = await _readChat(chatRef);
    {
      final participants = (chat['participants'] as List? ?? [])
          .map((id) => id.toString())
          .toList();
      final status = (chat['requestStatus'] ?? 'none').toString();
      final requesterId = chat['requesterId']?.toString();
      final chatUpdates = <String, dynamic>{
        'lastMessage': mediaType == 'location'
            ? text
            : mediaUrl != null
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

      if (chat['chatType'] == 'direct' && status == 'none') {
        if (chat['lastMessageAt'] == null) {
          final recipientId = participants.firstWhere(
            (id) => id != senderId,
            orElse: () => '',
          );
          if (recipientId.isNotEmpty) {
            chatUpdates.addAll({
              'requestStatus': 'pending',
              'requesterId': senderId,
              'requestRecipientId': recipientId,
            });
          }
        }
      }
      final batch = _firestore.batch();
      batch.set(messageRef, {
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
        ...?extra,
      });
      batch.update(chatRef, chatUpdates);
      // Not awaited by the chat screen: the message is already visible.
      await batch.commit();
    }

    // Notifications are created by the server (functions/social.js ->
    // notifyOnChatMessage), so a phone can no longer fake them.
  }

  Future<Map<String, dynamic>> _readChat(
    DocumentReference<Map<String, dynamic>> chatRef,
  ) async {
    try {
      final cached = await chatRef.get(const GetOptions(source: Source.cache));
      final data = cached.data();
      if (data != null) return data;
    } catch (_) {
      // Not in the cache yet: fall through to the server.
    }
    return (await chatRef.get()).data() ?? <String, dynamic>{};
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

  /// Sends a location pin. With [liveFor] it becomes a live location that
  /// the sender's phone keeps moving (see LiveLocationService) until it ends.
  /// Returns the new message id at once (the upload continues in the
  /// background, like normal messages).
  String sendLocation({
    required String chatId,
    required String senderId,
    required double lat,
    required double lng,
    double? accuracy,
    Duration? liveFor,
    Map<String, dynamic>? replyTo,
    void Function(Future<void> upload)? onUpload,
  }) {
    final live = liveFor != null;
    final messageId =
        _firestore.collection('chats').doc(chatId).collection('messages').doc().id;
    final sending = sendMessage(
      messageId: messageId,
      chatId: chatId,
      senderId: senderId,
      text: live ? '📍 Live location' : '📍 Location',
      mediaType: 'location',
      replyTo: replyTo,
      extra: {
        'location': {
          'lat': lat,
          'lng': lng,
          if (accuracy != null) 'accuracy': accuracy,
          'updatedAt': Timestamp.now(),
        },
        'live': live,
        if (live) 'liveUntil': Timestamp.fromDate(DateTime.now().add(liveFor)),
        if (live) 'liveEnded': false,
      },
    );
    onUpload?.call(sending);
    return messageId;
  }

  /// Moves the pin of a live location message (sender only, see rules).
  Future<void> updateLiveLocation({
    required String chatId,
    required String messageId,
    required double lat,
    required double lng,
    double? accuracy,
  }) {
    return _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId)
        .update({
      'location': {
        'lat': lat,
        'lng': lng,
        if (accuracy != null) 'accuracy': accuracy,
        'updatedAt': FieldValue.serverTimestamp(),
      },
    });
  }

  Future<void> stopLiveLocation({
    required String chatId,
    required String messageId,
  }) {
    return _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId)
        .update({'liveEnded': true, 'liveUntil': FieldValue.serverTimestamp()});
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

  /// "Clear chat" now clears it only for the current user: it saves the
  /// moment of clearing, and ChatMessagesController hides older messages for
  /// them.
  /// Before, it deleted every message for both people.
  Future<void> clearChatMessages(String chatId) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    await _firestore.collection('chats').doc(chatId).update({
      'clearedAt.$uid': FieldValue.serverTimestamp(),
    });
  }

  String _chatIdFor(String a, String b) {
    final ordered = [a, b]..sort();
    return '${ordered[0]}_${ordered[1]}';
  }
}
