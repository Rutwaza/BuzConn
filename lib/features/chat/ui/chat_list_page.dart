import 'package:flutter/material.dart';
import 'package:businessfinder/core/i18n/tr.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/colors.dart';
import 'package:businessfinder/features/chat/data/chat_repository.dart';
import 'chat_page.dart';

class ChatListPage extends StatefulWidget {
  const ChatListPage({super.key, this.initialFilter});

  final String? initialFilter;

  @override
  State<ChatListPage> createState() => _ChatListPageState();
}

class _ChatListPageState extends State<ChatListPage> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  _InboxFilter _filter = _InboxFilter.all;
  String? _selectedDesktopChatId;
  Map<String, dynamic>? _selectedDesktopMeta;

  Future<bool> _respondToMessageRequest({
    required String chatId,
    required String userId,
    required bool accept,
  }) async {
    try {
      await ChatRepository().respondToMessageRequest(
        chatId: chatId,
        userId: userId,
        accept: accept,
      );
      return true;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update request: $error')),
        );
      }
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialFilter == 'requests') {
      _filter = _InboxFilter.requests;
    }
  }

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
      final otherUserId = isUserA ? userBId : userAId;
      final title =
          isUserA ? (data['userBName'] ?? '') : (data['userAName'] ?? '');
      final avatarUrl = isUserA
          ? (data['userBImageUrl'] as String?)
          : (data['userAImageUrl'] as String?);
      if (otherUserId != null) {
        final userSnap =
            await firestore.collection('users').doc(otherUserId).get();
        final user = userSnap.data() ?? {};
        final name = user['name'] ?? 'Chat';
        final imageUrl = user['imageUrl'] as String?;
        final lastSeen = user['lastSeen'] as Timestamp?;
        return {
          'title': title.isEmpty ? name : title,
          'avatarUrl': avatarUrl ?? imageUrl,
          'lastSeen': lastSeen,
          'otherUserId': otherUserId,
        };
      }
      return {
        'title': title.isEmpty ? 'Chat' : title,
        'avatarUrl': avatarUrl,
        'lastSeen': null,
        'otherUserId': otherUserId,
      };
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
      final lastSeen = user['lastSeen'] as Timestamp?;
      return {
        'title': title.isEmpty ? 'Chat' : title,
        'avatarUrl': avatarUrl,
        'lastSeen': lastSeen,
        'otherUserId': clientId,
      };
    }

    if (!isBusinessOwner && businessId != null) {
      final bizSnap =
          await firestore.collection('businesses').doc(businessId).get();
      final biz = bizSnap.data() ?? {};
      if (title.isEmpty) title = biz['name'] ?? title;
      avatarUrl ??= biz['imageUrl'] as String?;
      final ownerId = data['businessOwnerId'] as String?;
      Timestamp? lastSeen;
      if (ownerId != null) {
        final ownerSnap =
            await firestore.collection('users').doc(ownerId).get();
        lastSeen = ownerSnap.data()?['lastSeen'] as Timestamp?;
      }
      return {
        'title': title.isEmpty ? 'Chat' : title,
        'avatarUrl': avatarUrl,
        'lastSeen': lastSeen,
        'otherUserId': ownerId,
      };
    }

    if (title.isEmpty) {
      final participants =
          (data['participants'] as List?)?.cast<String>() ?? [];
      final otherUserId = participants.firstWhere(
        (id) => id != currentUserId,
        orElse: () => '',
      );
      if (otherUserId.isNotEmpty) {
        final userSnap =
            await firestore.collection('users').doc(otherUserId).get();
        final user = userSnap.data() ?? {};
        title = user['name'] ?? title;
        avatarUrl ??= user['imageUrl'] as String?;
      }
    }

    if (title.isEmpty) {
      title = 'Chat';
    }

    return {
      'title': title,
      'avatarUrl': avatarUrl,
      'lastSeen': null,
      'otherUserId': null,
    };
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return Scaffold(
        body: Center(child: Text(tr('Please sign in.'))),
      );
    }

    final repo = ChatRepository();

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Inbox')),
        actions: [
          IconButton(
            tooltip: tr('Archived'),
            icon: Icon(
              _filter == _InboxFilter.archived
                  ? Icons.archive
                  : Icons.archive_outlined,
            ),
            onPressed: () {
              HapticFeedback.selectionClick();
              setState(() {
                _filter = _filter == _InboxFilter.archived
                    ? _InboxFilter.all
                    : _InboxFilter.archived;
              });
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          HapticFeedback.mediumImpact();
          context.push(AppRoutes.search);
        },
        backgroundColor: AppColors.primary,
        child: const Icon(Icons.edit_outlined, color: Colors.white),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isDesktopWide = constraints.maxWidth >= 1180;
          final inboxContent = Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            AppColors.primary.withValues(alpha: 0.16),
                            Colors.orange.withValues(alpha: 0.10),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: const Icon(
                              Icons.forum_rounded,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  tr('Your social inbox'),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  tr('Stay close to creators, friends, and fresh conversations.'),
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _searchController,
                      onChanged: (value) {
                        setState(() {
                          _searchQuery = value.trim().toLowerCase();
                        });
                      },
                      decoration: InputDecoration(
                        hintText: tr('Search messages'),
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: _searchQuery.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close_rounded),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() {
                                    _searchQuery = '';
                                  });
                                },
                              ),
                        filled: true,
                        fillColor: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha: 0.45),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _buildFilterChip(_InboxFilter.all, 'All'),
                          _buildFilterChip(_InboxFilter.requests, 'Requests'),
                          _buildFilterChip(_InboxFilter.unread, 'Unread'),
                          _buildFilterChip(_InboxFilter.creators, 'Creators'),
                          _buildFilterChip(_InboxFilter.archived, 'Archived'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: StreamBuilder<QuerySnapshot>(
                  stream: repo.userChatsStream(user.uid),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final docs = snapshot.data?.docs ?? [];
                    if (docs.isEmpty) {
                      return _buildEmptyState(
                        icon: Icons.forum_outlined,
                        title: tr('No conversations yet'),
                        subtitle:
                            tr('Start chatting from a profile or page to see your inbox come alive.'),
                      );
                    }

                    final filteredDocs = docs.where((doc) {
                      final data = doc.data() as Map<String, dynamic>;
                      final hiddenFor =
                          (data['hiddenFor'] as List?)?.cast<String>() ?? [];
                      final isArchived = hiddenFor.contains(user.uid);
                      final isCreatorChat =
                          (data['chatType'] ?? '').toString() == 'business';
                      final isIncomingRequest =
                          data['requestStatus'] == 'pending' &&
                              data['requestRecipientId'] == user.uid;
                      if (_filter == _InboxFilter.requests) {
                        if (!isIncomingRequest) return false;
                      } else if (isIncomingRequest) {
                        return false;
                      }
                      final lastMessageAt = data['lastMessageAt'] as Timestamp?;
                      final lastReadAt =
                          data['lastReadAt'] as Map<String, dynamic>? ?? {};
                      final lastReadForUser =
                          lastReadAt[user.uid] as Timestamp?;
                      final sentByMe =
                          (data['lastMessageSenderId'] as String?) == user.uid;
                      final unread = !sentByMe &&
                          lastMessageAt != null &&
                          (lastReadForUser == null ||
                              lastMessageAt.toDate().isAfter(
                                    lastReadForUser.toDate(),
                                  ));

                      if (_filter == _InboxFilter.archived) {
                        if (!isArchived) return false;
                      } else if (isArchived) {
                        return false;
                      }
                      if (_filter == _InboxFilter.unread && !unread) {
                        return false;
                      }
                      if (_filter == _InboxFilter.creators && !isCreatorChat) {
                        return false;
                      }
                      if (_searchQuery.isEmpty) return true;
                      final lastMessage =
                          (data['lastMessage'] ?? '').toString();
                      final aName = (data['userAName'] ?? '').toString();
                      final bName = (data['userBName'] ?? '').toString();
                      final businessName =
                          (data['businessName'] ?? '').toString();
                      final clientName = (data['clientName'] ?? '').toString();
                      final haystack =
                          '$lastMessage $aName $bName $businessName $clientName'
                              .toLowerCase();
                      return haystack.contains(_searchQuery);
                    }).toList();

                    if (filteredDocs.isEmpty) {
                      return _buildEmptyState(
                        icon: _filter == _InboxFilter.archived
                            ? Icons.archive_outlined
                            : Icons.chat_bubble_outline_rounded,
                        title: _searchQuery.isNotEmpty
                            ? 'No results for "$_searchQuery"'
                            : (_filter == _InboxFilter.archived
                                ? 'No archived chats'
                                : 'Nothing here yet'),
                        subtitle: _searchQuery.isNotEmpty
                            ? 'Try another name or message preview.'
                            : 'New conversations will show up here as soon as you start connecting.',
                      );
                    }

                    final sortedDocs = [...filteredDocs]..sort((a, b) {
                        final aData = a.data() as Map<String, dynamic>;
                        final bData = b.data() as Map<String, dynamic>;
                        final aTs = aData['lastMessageAt'] as Timestamp?;
                        final bTs = bData['lastMessageAt'] as Timestamp?;
                        final aMillis = aTs?.millisecondsSinceEpoch ?? 0;
                        final bMillis = bTs?.millisecondsSinceEpoch ?? 0;
                        return bMillis.compareTo(aMillis);
                      });

                    final recentDocs = sortedDocs.take(8).toList();
                    final hasSelectedVisibleChat =
                        _selectedDesktopChatId != null &&
                            sortedDocs
                                .any((doc) => doc.id == _selectedDesktopChatId);
                    if (isDesktopWide &&
                        sortedDocs.isNotEmpty &&
                        !hasSelectedVisibleChat) {
                      WidgetsBinding.instance.addPostFrameCallback((_) async {
                        if (!mounted) return;
                        final firstDoc = sortedDocs.first;
                        final firstData =
                            firstDoc.data() as Map<String, dynamic>;
                        final firstMeta =
                            await _resolveChatMeta(firstData, user.uid);
                        if (!mounted) return;
                        _selectDesktopChat(
                          chatId: firstDoc.id,
                          meta: firstMeta,
                        );
                      });
                    }

                    return ListView(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                      children: [
                        if (recentDocs.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          _RecentChatsRow(
                            docs: recentDocs,
                            currentUserId: user.uid,
                            resolveChatMeta: _resolveChatMeta,
                          ),
                          const SizedBox(height: 14),
                        ],
                        ...sortedDocs.map((doc) {
                          final data = doc.data() as Map<String, dynamic>;
                          final isIncomingRequest =
                              data['requestStatus'] == 'pending' &&
                                  data['requestRecipientId'] == user.uid;
                          final chatId = doc.id;
                          final lastMessage =
                              (data['lastMessage'] ?? '').toString();
                          final lastMessageAt =
                              data['lastMessageAt'] as Timestamp?;
                          final lastReadAt =
                              data['lastReadAt'] as Map<String, dynamic>? ?? {};
                          final lastReadForUser =
                              lastReadAt[user.uid] as Timestamp?;
                          final sentByMe =
                              (data['lastMessageSenderId'] as String?) ==
                                  user.uid;
                          final unread = !sentByMe &&
                              lastMessageAt != null &&
                              (lastReadForUser == null ||
                                  lastMessageAt.toDate().isAfter(
                                        lastReadForUser.toDate(),
                                      ));
                          final isArchived = (data['hiddenFor'] as List?)
                                  ?.cast<String>()
                                  .contains(user.uid) ??
                              false;
                          final isCreatorChat =
                              (data['chatType'] ?? '').toString() == 'business';

                          return FutureBuilder<Map<String, dynamic>>(
                            future: _resolveChatMeta(data, user.uid),
                            builder: (context, metaSnap) {
                              final meta = metaSnap.data ?? {};
                              final title = meta['title'] as String? ?? 'Chat';
                              final avatarUrl = meta['avatarUrl'] as String?;
                              final lastSeen = meta['lastSeen'] as Timestamp?;
                              final participants =
                                  (data['participants'] as List?)
                                          ?.cast<String>() ??
                                      [];
                              final otherUserId = participants.firstWhere(
                                (id) => id != user.uid,
                                orElse: () => '',
                              );
                              final otherLastRead = otherUserId.isNotEmpty
                                  ? lastReadAt[otherUserId] as Timestamp?
                                  : null;
                              final isReadByOther = sentByMe &&
                                  lastMessageAt != null &&
                                  otherLastRead != null &&
                                  !otherLastRead
                                      .toDate()
                                      .isBefore(lastMessageAt.toDate());
                              final isDeliveredToOther = sentByMe &&
                                  lastMessageAt != null &&
                                  ((lastSeen != null &&
                                          !lastSeen.toDate().isBefore(
                                              lastMessageAt.toDate())) ||
                                      isReadByOther);
                              if (_searchQuery.isNotEmpty &&
                                  !title.toLowerCase().contains(_searchQuery) &&
                                  !lastMessage
                                      .toLowerCase()
                                      .contains(_searchQuery)) {
                                return const SizedBox.shrink();
                              }

                              return Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Dismissible(
                                  key: ValueKey('chat_$chatId'),
                                  direction: DismissDirection.endToStart,
                                  confirmDismiss: (_) async {
                                    HapticFeedback.lightImpact();
                                    await _toggleArchivedState(
                                      chatId: chatId,
                                      isHidden: isArchived,
                                    );
                                    return false;
                                  },
                                  background: _buildSwipeBackground(isArchived),
                                  child: _ChatPreviewCard(
                                    title: title,
                                    avatarUrl: avatarUrl,
                                    isUnread: unread,
                                    isCreatorChat: isCreatorChat,
                                    lastMessage: _formatPreview(lastMessage),
                                    timeLabel: _formatTimeAgo(lastMessageAt),
                                    isOnline: _isActuallyOnline(lastSeen),
                                    activityLabel: _formatActivity(lastSeen),
                                    sentByMe: sentByMe,
                                    isDeliveredToOther: isDeliveredToOther,
                                    isReadByOther: isReadByOther,
                                    isMessageRequest: isIncomingRequest,
                                    onApproveRequest: isIncomingRequest
                                        ? () async {
                                            final accepted =
                                                await _respondToMessageRequest(
                                              chatId: chatId,
                                              userId: user.uid,
                                              accept: true,
                                            );
                                            if (!accepted || !mounted) return;
                                            if (isDesktopWide) {
                                              _filter = _InboxFilter.all;
                                              _selectDesktopChat(
                                                chatId: chatId,
                                                meta: meta,
                                              );
                                            } else {
                                              context.push(AppRoutes
                                                  .chatDetailPath(chatId));
                                            }
                                          }
                                        : null,
                                    onRejectRequest: isIncomingRequest
                                        ? () => _respondToMessageRequest(
                                              chatId: chatId,
                                              userId: user.uid,
                                              accept: false,
                                            )
                                        : null,
                                    isSelected: isDesktopWide &&
                                        _selectedDesktopChatId == chatId,
                                    onTap: () async {
                                      HapticFeedback.selectionClick();
                                      if (isIncomingRequest) {
                                        if (isDesktopWide) {
                                          _selectDesktopChat(
                                            chatId: chatId,
                                            meta: meta,
                                          );
                                        } else {
                                          context.push(AppRoutes
                                              .chatDetailPath(chatId));
                                        }
                                        return;
                                      }
                                      if (isDesktopWide) {
                                        _selectDesktopChat(
                                          chatId: chatId,
                                          meta: meta,
                                        );
                                      } else {
                                        context.push(
                                            AppRoutes.chatDetailPath(chatId));
                                      }
                                    },
                                    onLongPress: () => _showChatActions(
                                      chatId: chatId,
                                      isHidden: isArchived,
                                    ),
                                  ),
                                ),
                              );
                            },
                          );
                        }),
                      ],
                    );
                  },
                ),
              ),
            ],
          );

          if (!isDesktopWide) {
            return inboxContent;
          }

          return Padding(
            padding: const EdgeInsets.only(right: 16, bottom: 12),
            child: Row(
              children: [
                Expanded(
                  flex: 4,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 500),
                      child: inboxContent,
                    ),
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  flex: 6,
                  child: _selectedDesktopChatId == null
                      ? _DesktopInboxPanel(
                          filterLabel: _desktopFilterLabel(_filter),
                          onDiscover: () => context.push(AppRoutes.search),
                          onCompose: () => context.push(AppRoutes.search),
                        )
                      : _DesktopChatShell(
                          key: ValueKey(_selectedDesktopChatId),
                          chatId: _selectedDesktopChatId!,
                          title: _selectedDesktopMeta?['title'] as String? ??
                              'Chat',
                          avatarUrl:
                              _selectedDesktopMeta?['avatarUrl'] as String?,
                          activityLabel: _formatActivity(
                              _selectedDesktopMeta?['lastSeen'] as Timestamp?),
                          onBackToList: () {
                            setState(() {
                              _selectedDesktopChatId = null;
                              _selectedDesktopMeta = null;
                            });
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _desktopFilterLabel(_InboxFilter filter) {
    switch (filter) {
      case _InboxFilter.unread:
        return 'Unread';
      case _InboxFilter.creators:
        return 'Creators';
      case _InboxFilter.archived:
        return 'Archived';
      case _InboxFilter.all:
        return 'All';
      case _InboxFilter.requests:
        return 'Requests';
    }
  }

  void _selectDesktopChat({
    required String chatId,
    required Map<String, dynamic> meta,
  }) {
    setState(() {
      _selectedDesktopChatId = chatId;
      _selectedDesktopMeta = meta;
    });
  }

  Widget _buildFilterChip(_InboxFilter filter, String label) {
    final selected = _filter == filter;
    final user = FirebaseAuth.instance.currentUser;
    if (filter == _InboxFilter.requests && user != null) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('chats')
              .where('participants', arrayContains: user.uid)
              .snapshots(),
          builder: (context, snapshot) {
            final hasRequests = (snapshot.data?.docs ?? []).any((doc) {
              final data = doc.data() as Map<String, dynamic>;
              return data['requestStatus'] == 'pending' &&
                  data['requestRecipientId'] == user.uid;
            });
            return ChoiceChip(
              selected: selected,
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label),
                  if (hasRequests) ...[
                    const SizedBox(width: 7),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Colors.redAccent,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ],
              ),
              onSelected: (_) {
                HapticFeedback.selectionClick();
                setState(() => _filter = filter);
              },
            );
          },
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        selected: selected,
        label: Text(label),
        onSelected: (_) {
          HapticFeedback.selectionClick();
          setState(() {
            _filter = filter;
          });
        },
      ),
    );
  }

  String _formatPreview(String lastMessage) {
    final normalized = lastMessage.trim();
    if (normalized == '[media]') return 'Shared media';
    if (normalized.isEmpty) return 'Say something new';
    return normalized;
  }

  bool _isActuallyOnline(Timestamp? lastSeen) {
    if (lastSeen == null) return false;
    return DateTime.now().difference(lastSeen.toDate()).inMinutes < 3;
  }

  String _formatActivity(Timestamp? lastSeen) {
    if (_isActuallyOnline(lastSeen)) return 'Active now';
    if (lastSeen == null) return 'Offline';
    final difference = DateTime.now().difference(lastSeen.toDate());
    if (difference.inMinutes < 60) return 'Active ${difference.inMinutes}m ago';
    if (difference.inHours < 24) return 'Active ${difference.inHours}h ago';
    return 'Active ${difference.inDays}d ago';
  }

  String _formatTimeAgo(Timestamp? timestamp) {
    if (timestamp == null) return '';
    final difference = DateTime.now().difference(timestamp.toDate());
    if (difference.inDays > 0) return '${difference.inDays}d';
    if (difference.inHours > 0) return '${difference.inHours}h';
    if (difference.inMinutes > 0) return '${difference.inMinutes}m';
    return 'now';
  }

  Widget _buildSwipeBackground(bool isArchived) {
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      decoration: BoxDecoration(
        color: isArchived
            ? Colors.green.withValues(alpha: 0.18)
            : Colors.orange.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Icon(
        isArchived ? Icons.unarchive_rounded : Icons.archive_rounded,
        color: isArchived ? Colors.green : Colors.orange,
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 34, color: AppColors.primary),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.grey,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleArchivedState({
    required String chatId,
    required bool isHidden,
  }) async {
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

  Future<void> _showChatActions({
    required String chatId,
    required bool isHidden,
  }) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: Wrap(
            children: [
              const SizedBox(height: 10),
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              ListTile(
                leading: Icon(isHidden ? Icons.unarchive : Icons.archive),
                title: Text(isHidden ? 'Unhide chat' : 'Archive chat'),
                subtitle: Text(
                  tr('Tidy your inbox without deleting the conversation.'),
                ),
                onTap: () => Navigator.pop(context, 'toggle'),
              ),
            ],
          ),
        );
      },
    );

    if (action == 'toggle') {
      await _toggleArchivedState(chatId: chatId, isHidden: isHidden);
    }
  }
}

enum _InboxFilter { all, unread, creators, archived, requests }

class _DesktopChatShell extends StatelessWidget {
  const _DesktopChatShell({
    super.key,
    required this.chatId,
    required this.title,
    required this.avatarUrl,
    required this.activityLabel,
    required this.onBackToList,
  });

  final String chatId;
  final String title;
  final String? avatarUrl;
  final String activityLabel;
  final VoidCallback onBackToList;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF121720) : Colors.white,
        borderRadius: BorderRadius.circular(32),
        border: Border.all(
          color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.06),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 26,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.03)
                  : AppColors.primary.withValues(alpha: 0.05),
              border: Border(
                bottom: BorderSide(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : Colors.black.withValues(alpha: 0.05),
                ),
              ),
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: tr('Back to inbox'),
                  onPressed: onBackToList,
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                const SizedBox(width: 6),
                CircleAvatar(
                  radius: 22,
                  backgroundColor: AppColors.primary,
                  backgroundImage: avatarUrl != null && avatarUrl!.isNotEmpty
                      ? NetworkImage(avatarUrl!)
                      : null,
                  child: avatarUrl == null || avatarUrl!.isEmpty
                      ? Text(
                          title.isNotEmpty ? title[0].toUpperCase() : '?',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        )
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        activityLabel,
                        style: TextStyle(
                          color: isDark ? Colors.white60 : AppColors.grey,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    tr('Desktop chat'),
                    style: const TextStyle(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ChatPage(
              chatId: chatId,
              embedded: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopInboxPanel extends StatefulWidget {
  const _DesktopInboxPanel({
    required this.filterLabel,
    required this.onDiscover,
    required this.onCompose,
  });

  final String filterLabel;
  final VoidCallback onDiscover;
  final VoidCallback onCompose;

  @override
  State<_DesktopInboxPanel> createState() => _DesktopInboxPanelState();
}

class _DesktopInboxPanelState extends State<_DesktopInboxPanel> {
  int _hoveredIndex = -1;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 14),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: 0.34),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('Desktop Inbox'),
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Text(
                  'Your current focus is ${widget.filterLabel.toLowerCase()} chats. Use the extra room to keep conversations and discovery moving together.',
                  style: const TextStyle(
                    color: AppColors.grey,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 18),
                _desktopAction(
                  index: 0,
                  icon: Icons.travel_explore_rounded,
                  title: tr('Discover people to message'),
                  subtitle:
                      tr('Jump into profiles, pages, and fresh conversations.'),
                  onTap: widget.onDiscover,
                ),
                const SizedBox(height: 12),
                _desktopAction(
                  index: 1,
                  icon: Icons.edit_rounded,
                  title: tr('Compose a new message'),
                  subtitle:
                      tr('Use search to start a direct or creator conversation.'),
                  onTap: widget.onCompose,
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr('Desktop feel'),
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: AppColors.primary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        tr('Hover targets, wider reading space, and a calmer two-pane inbox make the social flow feel more natural on Windows.'),
                        style: const TextStyle(
                          color: AppColors.grey,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _desktopAction({
    required int index,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final hovered = _hoveredIndex == index;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hoveredIndex = index),
      onExit: (_) => setState(() => _hoveredIndex = -1),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: hovered
              ? AppColors.primary.withValues(alpha: 0.10)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(22),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, color: AppColors.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          style: const TextStyle(
                            color: AppColors.grey,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.arrow_forward_ios_rounded, size: 14),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RecentChatsRow extends StatelessWidget {
  const _RecentChatsRow({
    required this.docs,
    required this.currentUserId,
    required this.resolveChatMeta,
  });

  final List<QueryDocumentSnapshot<Object?>> docs;
  final String currentUserId;
  final Future<Map<String, dynamic>> Function(
    Map<String, dynamic>,
    String,
  ) resolveChatMeta;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 104,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: docs.length,
        separatorBuilder: (_, __) => const SizedBox(width: 14),
        itemBuilder: (context, index) {
          final data = docs[index].data() as Map<String, dynamic>;
          final chatId = docs[index].id;
          return FutureBuilder<Map<String, dynamic>>(
            future: resolveChatMeta(data, currentUserId),
            builder: (context, snap) {
              final meta = snap.data ?? {};
              final title = meta['title'] as String? ?? 'Chat';
              final avatarUrl = meta['avatarUrl'] as String?;
              final lastSeen = meta['lastSeen'] as Timestamp?;
              final active = lastSeen != null &&
                  DateTime.now().difference(lastSeen.toDate()).inMinutes < 3;
              return InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () {
                  HapticFeedback.selectionClick();
                  context.push(AppRoutes.chatDetailPath(chatId));
                },
                child: SizedBox(
                  width: 78,
                  child: Column(
                    children: [
                      Stack(
                        children: [
                          CircleAvatar(
                            radius: 28,
                            backgroundColor: Theme.of(context)
                                .dividerColor
                                .withValues(alpha: 0.6),
                            child: CircleAvatar(
                              radius: 25,
                              backgroundColor: AppColors.primary,
                              backgroundImage: avatarUrl != null
                                  ? NetworkImage(avatarUrl)
                                  : null,
                              child: avatarUrl == null
                                  ? Text(
                                      title.isNotEmpty
                                          ? title[0].toUpperCase()
                                          : '?',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    )
                                  : null,
                            ),
                          ),
                          if (active)
                            Positioned(
                              right: 2,
                              bottom: 2,
                              child: Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                  color: Colors.greenAccent,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Theme.of(context)
                                        .scaffoldBackgroundColor,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _ChatPreviewCard extends StatelessWidget {
  const _ChatPreviewCard({
    required this.title,
    required this.avatarUrl,
    required this.isUnread,
    required this.isCreatorChat,
    required this.lastMessage,
    required this.timeLabel,
    required this.isOnline,
    required this.activityLabel,
    required this.sentByMe,
    required this.isDeliveredToOther,
    required this.isReadByOther,
    this.isMessageRequest = false,
    this.onApproveRequest,
    this.onRejectRequest,
    this.isSelected = false,
    required this.onTap,
    required this.onLongPress,
  });

  final String title;
  final String? avatarUrl;
  final bool isUnread;
  final bool isCreatorChat;
  final String lastMessage;
  final String timeLabel;
  final bool isOnline;
  final String activityLabel;
  final bool sentByMe;
  final bool isDeliveredToOther;
  final bool isReadByOther;
  final bool isMessageRequest;
  final VoidCallback? onApproveRequest;
  final VoidCallback? onRejectRequest;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        mouseCursor: SystemMouseCursors.click,
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(24),
        child: Ink(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isUnread
                ? AppColors.primary.withValues(alpha: 0.08)
                : isSelected
                    ? AppColors.primary.withValues(alpha: 0.10)
                    : Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest
                        .withValues(alpha: 0.28),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isUnread
                  ? AppColors.primary.withValues(alpha: 0.24)
                  : isSelected
                      ? AppColors.primary.withValues(alpha: 0.20)
                      : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Stack(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: AppColors.primary,
                    backgroundImage:
                        avatarUrl != null ? NetworkImage(avatarUrl!) : null,
                    child: avatarUrl == null
                        ? Text(
                            title.isNotEmpty ? title[0].toUpperCase() : '?',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          )
                        : null,
                  ),
                  if (isOnline)
                    Positioned(
                      right: 1,
                      bottom: 1,
                      child: Container(
                        width: 13,
                        height: 13,
                        decoration: BoxDecoration(
                          color: Colors.greenAccent,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Theme.of(context).scaffoldBackgroundColor,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight:
                                  isUnread ? FontWeight.w800 : FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                        ),
                        if (timeLabel.isNotEmpty)
                          Text(
                            timeLabel,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight:
                                  isUnread ? FontWeight.w700 : FontWeight.w600,
                              color:
                                  isUnread ? AppColors.primary : AppColors.grey,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: isCreatorChat
                                ? Colors.orange.withValues(alpha: 0.14)
                                : AppColors.primary.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            isCreatorChat ? 'Creator' : 'Direct',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: isCreatorChat
                                  ? Colors.orange.shade700
                                  : AppColors.primary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Row(
                            children: [
                              if (sentByMe) ...[
                                _MessageReceiptIcon(
                                  delivered: isDeliveredToOther,
                                  read: isReadByOther,
                                ),
                                const SizedBox(width: 6),
                              ],
                              Expanded(
                                child: Text(
                                  lastMessage,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isUnread
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: isUnread
                                        ? Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                        : AppColors.grey,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      activityLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isOnline ? Colors.green : AppColors.grey,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (isMessageRequest) ...[
                _requestAction(
                  tooltip: tr('Approve request'),
                  icon: Icons.check_rounded,
                  color: const Color(0xFF198754),
                  onPressed: onApproveRequest,
                ),
                _requestAction(
                  tooltip: tr('Reject request'),
                  icon: Icons.close_rounded,
                  color: const Color(0xFFB3261E),
                  onPressed: onRejectRequest,
                ),
              ] else if (isUnread)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    tr('New'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _requestAction({
    required String tooltip,
    required IconData icon,
    required Color color,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 38, height: 42),
      padding: EdgeInsets.zero,
      icon: Icon(icon, color: color, size: 21),
    );
  }
}

class _MessageReceiptIcon extends StatelessWidget {
  const _MessageReceiptIcon({
    required this.delivered,
    required this.read,
  });

  final bool delivered;
  final bool read;

  @override
  Widget build(BuildContext context) {
    if (!delivered) {
      return const Icon(
        Icons.done_rounded,
        size: 16,
        color: AppColors.grey,
      );
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(
          Icons.done_rounded,
          size: 16,
          color: read ? Colors.lightBlueAccent : AppColors.grey,
        ),
        Positioned(
          left: 6,
          child: Icon(
            Icons.done_rounded,
            size: 16,
            color: read ? Colors.lightBlueAccent : AppColors.grey,
          ),
        ),
      ],
    );
  }
}
