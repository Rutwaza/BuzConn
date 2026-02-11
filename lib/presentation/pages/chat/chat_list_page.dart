import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/colors.dart';
import '../../../data/repositories/chat_repository.dart';

class ChatListPage extends StatefulWidget {
  const ChatListPage({super.key});

  @override
  State<ChatListPage> createState() => _ChatListPageState();
}

class _ChatListPageState extends State<ChatListPage> {
  bool _showHidden = false;

  Future<Map<String, dynamic>> _resolveChatMeta(
    Map<String, dynamic> data,
    String currentUserId,
  ) async {
    final firestore = FirebaseFirestore.instance;
    final isBusinessOwner = data['businessOwnerId'] == currentUserId;
    final chatType = (data['chatType'] ?? '').toString();

    if (chatType == 'direct') {
      final userAId = data['userAId'] as String?;
      final userBId = data['userBId'] as String?;
      final isUserA = userAId == currentUserId;
      final title = isUserA
          ? (data['userBName'] ?? '')
          : (data['userAName'] ?? '');
      final avatarUrl = isUserA
          ? (data['userBImageUrl'] as String?)
          : (data['userAImageUrl'] as String?);
      if (title.isNotEmpty || avatarUrl != null) {
        return {'title': title.isEmpty ? 'Chat' : title, 'avatarUrl': avatarUrl};
      }
      final otherUserId = isUserA ? userBId : userAId;
      if (otherUserId != null) {
        final userSnap =
            await firestore.collection('users').doc(otherUserId).get();
        final user = userSnap.data() ?? {};
        final name = user['name'] ?? 'Chat';
        final imageUrl = user['imageUrl'] as String?;
        return {'title': name, 'avatarUrl': imageUrl};
      }
      return {'title': 'Chat', 'avatarUrl': null};
    }

    String title = isBusinessOwner
        ? (data['clientName'] ?? '')
        : (data['businessName'] ?? '');
    String? avatarUrl = isBusinessOwner
        ? (data['clientImageUrl'] as String?)
        : (data['businessImageUrl'] as String?);

    if (title.isNotEmpty && avatarUrl != null) {
      return {'title': title, 'avatarUrl': avatarUrl};
    }

    // Fallback: fetch live data (prefer explicit ids).
    final clientId = data['clientId'] as String?;
    final businessId = data['businessId'] as String?;

    if (isBusinessOwner && clientId != null) {
      final userSnap = await firestore.collection('users').doc(clientId).get();
      final user = userSnap.data() ?? {};
      if (title.isEmpty) title = user['name'] ?? title;
      avatarUrl ??= user['imageUrl'] as String?;
    }

    if (!isBusinessOwner && businessId != null) {
      final bizSnap =
          await firestore.collection('businesses').doc(businessId).get();
      final biz = bizSnap.data() ?? {};
      if (title.isEmpty) title = biz['name'] ?? title;
      avatarUrl ??= biz['imageUrl'] as String?;
    }

    if (title.isEmpty) {
      final participants = (data['participants'] as List?)?.cast<String>() ?? [];
      final otherUserId = participants.firstWhere(
        (id) => id != currentUserId,
        orElse: () => '',
      );
      if (otherUserId.isNotEmpty) {
        final userSnap = await firestore.collection('users').doc(otherUserId).get();
        final user = userSnap.data() ?? {};
        title = user['name'] ?? title;
        avatarUrl ??= user['imageUrl'] as String?;
      }
    }

    if (title.isEmpty) {
      title = 'Chat';
    }

    return {'title': title, 'avatarUrl': avatarUrl};
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Scaffold(
        body: Center(child: Text('Please sign in.')),
      );
    }

    final repo = ChatRepository();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Messages'),
        actions: [
          IconButton(
            tooltip: _showHidden ? 'Hide archived' : 'Show archived',
            icon: Icon(_showHidden ? Icons.visibility_off : Icons.visibility),
            onPressed: () {
              setState(() {
                _showHidden = !_showHidden;
              });
            },
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: repo.userChatsStream(user.uid),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snapshot.data?.docs ?? [];
          if (docs.isEmpty) {
            return const Center(child: Text('No conversations yet.'));
          }

          final filteredDocs = docs.where((doc) {
            final data = doc.data() as Map<String, dynamic>;
            final hiddenFor =
                (data['hiddenFor'] as List?)?.cast<String>() ?? [];
            return _showHidden ? hiddenFor.contains(user.uid) : !hiddenFor.contains(user.uid);
          }).toList();

          if (filteredDocs.isEmpty) {
            return Center(
              child: Text(
                _showHidden ? 'No hidden chats.' : 'No conversations yet.',
              ),
            );
          }

          final sortedDocs = [...filteredDocs]
            ..sort((a, b) {
              final aData = a.data() as Map<String, dynamic>;
              final bData = b.data() as Map<String, dynamic>;
              final aTs = aData['lastMessageAt'] as Timestamp?;
              final bTs = bData['lastMessageAt'] as Timestamp?;
              final aMillis = aTs?.millisecondsSinceEpoch ?? 0;
              final bMillis = bTs?.millisecondsSinceEpoch ?? 0;
              return bMillis.compareTo(aMillis);
            });

          return ListView.builder(
            itemCount: sortedDocs.length,
            itemBuilder: (context, index) {
              final data = sortedDocs[index].data() as Map<String, dynamic>;
              final chatId = sortedDocs[index].id;
              final lastMessage = data['lastMessage'] ?? '';
              final lastMessageAt = data['lastMessageAt'] as Timestamp?;
              final lastReadAt = data['lastReadAt'] as Map<String, dynamic>? ?? {};
              final lastReadForUser = lastReadAt[user.uid] as Timestamp?;
              final unread = lastMessageAt != null &&
                  (lastReadForUser == null ||
                      lastMessageAt.toDate().isAfter(lastReadForUser.toDate()));

              return FutureBuilder<Map<String, dynamic>>(
                future: _resolveChatMeta(data, user.uid),
                builder: (context, metaSnap) {
                  final meta = metaSnap.data ?? {};
                  final title = meta['title'] as String? ?? 'Chat';
                  final avatarUrl = meta['avatarUrl'] as String?;

                  return Column(
                    children: [
                      GestureDetector(
                        onLongPress: () => _showChatActions(
                          chatId: chatId,
                          isHidden: (data['hiddenFor'] as List?)
                                  ?.cast<String>()
                                  .contains(user.uid) ??
                              false,
                        ),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: AppColors.primary,
                            backgroundImage:
                                avatarUrl != null ? NetworkImage(avatarUrl) : null,
                            child: avatarUrl == null
                                ? Text(
                                    title.toString().isNotEmpty
                                        ? title[0].toUpperCase()
                                        : '?',
                                    style: const TextStyle(color: Colors.white),
                                  )
                                : null,
                          ),
                          title: Text(title),
                          subtitle: Text(lastMessage,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: unread
                              ? const Icon(Icons.circle,
                                  color: Colors.red, size: 10)
                              : null,
                          onTap: () {
                            context.push(AppRoutes.chatDetailPath(chatId));
                          },
                        ),
                      ),
                      const Divider(height: 1),
                    ],
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _showChatActions({
    required String chatId,
    required bool isHidden,
  }) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: Icon(isHidden ? Icons.unarchive : Icons.archive),
                title: Text(isHidden ? 'Unhide chat' : 'Hide chat'),
                onTap: () => Navigator.pop(context, 'toggle'),
              ),
            ],
          ),
        );
      },
    );

    if (action == 'toggle') {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final ref = FirebaseFirestore.instance.collection('chats').doc(chatId);
      await ref.update({
        'hiddenFor': isHidden
            ? FieldValue.arrayRemove([user.uid])
            : FieldValue.arrayUnion([user.uid]),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
  }
}
