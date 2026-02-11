import 'dart:typed_data';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/colors.dart';
import '../../../core/services/supabase_storage_service.dart';
import '../../../data/repositories/chat_repository.dart';
import '../../../core/constants/app_constants.dart';
import '../feed/video_player_page.dart';

class ChatPage extends StatefulWidget {
  final String chatId;

  const ChatPage({super.key, required this.chatId});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _controller = TextEditingController();
  final _repo = ChatRepository();
  final _thumbCache = <String, Future<Uint8List?>>{};
  Map<String, dynamic>? _replyingTo;
  bool _sendingMedia = false;
  String? _lastReadMessageId;
  bool _isTyping = false;
  Timer? _typingTimer;

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      _repo.setLastRead(chatId: widget.chatId, userId: user.uid);
      _repo.setUserLastSeen(user.uid);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _typingTimer?.cancel();
    _setTyping(false);
    super.dispose();
  }

  Future<void> _sendText() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    await _setTyping(false);
    await _repo.sendMessage(
      chatId: widget.chatId,
      senderId: user.uid,
      text: text,
      replyTo: _replyingTo,
    );
    _controller.clear();
    setState(() {
      _replyingTo = null;
    });
  }

  Future<void> _sendMedia(ImageSource source, {required bool isVideo}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final picker = ImagePicker();
    final picked = isVideo
        ? await picker.pickVideo(source: source)
        : await picker.pickImage(source: source);
    if (picked == null) return;

    setState(() {
      _sendingMedia = true;
    });
    try {
      await _setTyping(false);
      final bytes = await picked.readAsBytes();
      final ext = isVideo ? 'mp4' : 'jpg';
      final path = '${user.uid}/${DateTime.now().millisecondsSinceEpoch}.$ext';
      final url = isVideo
        ? await SupabaseStorageService.instance.uploadVideo(
              bucket: 'chat-media', path: path, bytes: bytes)
          : await SupabaseStorageService.instance.uploadImage(
              bucket: 'chat-media', path: path, bytes: bytes);

      if (url == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Upload failed. Try again.')),
          );
        }
        return;
      }
      await _repo.sendMessage(
        chatId: widget.chatId,
        senderId: user.uid,
        text: '',
        mediaUrl: url,
        mediaType: isVideo ? 'video' : 'image',
        replyTo: _replyingTo,
      );
      setState(() {
        _replyingTo = null;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Media send failed: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _sendingMedia = false;
        });
      }
    }
  }

  Future<Uint8List?> _getVideoThumbnail(String url) {
    return _thumbCache.putIfAbsent(
      url,
      () => VideoThumbnail.thumbnailData(
        video: url,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 420,
        quality: 70,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Scaffold(body: Center(child: Text('Please sign in.')));
    }

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .snapshots(),
      builder: (context, chatSnap) {
        final chatData = chatSnap.data?.data() as Map<String, dynamic>? ?? {};
        final chatType = (chatData['chatType'] ?? '').toString();
        final isBusinessOwner = chatData['businessOwnerId'] == user.uid;
        String title;
        String? avatarUrl;
        String? otherUserId;
        if (chatType == 'direct') {
          final userAId = chatData['userAId'] as String?;
          final userBId = chatData['userBId'] as String?;
          final isUserA = userAId == user.uid;
          title = isUserA
              ? (chatData['userBName'] ?? 'Chat')
              : (chatData['userAName'] ?? 'Chat');
          avatarUrl = isUserA
              ? (chatData['userBImageUrl'] as String?)
              : (chatData['userAImageUrl'] as String?);
          otherUserId = isUserA ? userBId : userAId;
        } else {
          title = isBusinessOwner
              ? (chatData['clientName'] ?? 'Chat')
              : (chatData['businessName'] ?? 'Chat');
          avatarUrl = isBusinessOwner
              ? (chatData['clientImageUrl'] as String?)
              : (chatData['businessImageUrl'] as String?);
          otherUserId = isBusinessOwner
              ? chatData['clientId']
              : chatData['businessOwnerId'];
        }
        final otherLastRead = (chatData['lastReadAt'] as Map<String, dynamic>?)
            ?[otherUserId] as Timestamp?;
        final typingMap =
            (chatData['typing'] as Map<String, dynamic>?) ?? const {};
        final isOtherTyping =
            otherUserId != null && typingMap[otherUserId] == true;

        final isDark = Theme.of(context).brightness == Brightness.dark;
        final backgroundColor =
            isDark ? const Color(0xFF0F1115) : const Color(0xFFF4F6FA);
        final surfaceColor = isDark ? const Color(0xFF151922) : Colors.white;
        final bubbleMeColor = isDark ? const Color(0xFF3B82F6) : AppColors.primary;
        final bubbleOtherColor = surfaceColor;
        final separatorColor = isDark ? Colors.white10 : Colors.black12;
        final replyBarColor = isDark ? const Color(0xFF1C212B) : AppColors.lightGrey;
        final inputBarColor = surfaceColor;
        final emojiBarColor = surfaceColor;
        final typingColor = isDark ? Colors.white70 : AppColors.grey;

        return Scaffold(
          backgroundColor: backgroundColor,
          appBar: AppBar(
            title: Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: AppColors.primary,
                  backgroundImage:
                      avatarUrl != null ? NetworkImage(avatarUrl) : null,
                  child: avatarUrl == null
                      ? Text(
                          title.toString().isNotEmpty
                              ? title[0].toUpperCase()
                              : '?',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        )
                      : null,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (chatType != 'direct' &&
                    !isBusinessOwner &&
                    chatData['businessId'] != null)
                  TextButton(
                    onPressed: () {
                      final businessId = chatData['businessId'] as String?;
                      if (businessId != null && context.mounted) {
                        context.push(AppRoutes.businessProfilePath(businessId));
                      }
                    },
                    child: const Text('View profile'),
                  ),
              ],
            ),
          ),
          body: Column(
            children: [
              Expanded(
                child: StreamBuilder<QuerySnapshot>(
                  stream: _repo.messagesStream(widget.chatId),
                  builder: (context, snapshot) {
                    final docs = snapshot.data?.docs ?? [];
                    if (snapshot.connectionState == ConnectionState.waiting &&
                        docs.isEmpty) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (docs.isNotEmpty) {
                      final latest = docs.first.data() as Map<String, dynamic>;
                      final latestSender = latest['senderId'] as String?;
                      final latestId = latest['id'] ?? docs.first.id;
                      if (latestSender != null &&
                          latestSender != user.uid &&
                          _lastReadMessageId != latestId) {
                        _lastReadMessageId = latestId;
                        _repo.setLastRead(
                          chatId: widget.chatId,
                          userId: user.uid,
                        );
                      }
                    }
                    return ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.all(12),
                      itemCount: docs.length,
                      itemBuilder: (context, index) {
                        final doc = docs[index];
                        final data = doc.data() as Map<String, dynamic>;
                        final isMe = data['senderId'] == user.uid;
                    final text = data['text'] ?? '';
                    final mediaUrl = data['mediaUrl'] as String?;
                    final mediaType = data['mediaType'] as String?;
                    final senderName = data['senderName'] ?? 'User';
                    final senderAvatar = data['senderAvatar'] as String?;
                    final createdAt = data['createdAt'] as Timestamp?;
                    final replyTo = data['replyTo'] as Map<String, dynamic>?;
                    final deleted = data['deleted'] == true;
                    final messageId = data['id'] ?? doc.id;

                    Widget content;
                    if (deleted) {
                      content = const Text(
                        'Message deleted',
                        style: TextStyle(
                          fontStyle: FontStyle.italic,
                          color: AppColors.grey,
                        ),
                      );
                    } else if (mediaUrl != null && mediaType == 'image') {
                      content = Image.network(mediaUrl, width: 200);
                    } else if (mediaUrl != null && mediaType == 'video') {
                      content = FutureBuilder<Uint8List?>(
                        future: _getVideoThumbnail(mediaUrl),
                        builder: (context, snap) {
                          final bytes = snap.data;
                          return InkWell(
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => VideoPlayerPage(url: mediaUrl),
                                ),
                              );
                            },
                            child: Container(
                              width: 200,
                              height: 120,
                              color: replyBarColor,
                              child: bytes == null
                                  ? const Center(
                                      child: Icon(Icons.play_circle_fill,
                                          size: 36),
                                    )
                                  : Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Image.memory(bytes, fit: BoxFit.cover),
                                        const Center(
                                          child: Icon(Icons.play_circle_fill,
                                              size: 36),
                                        ),
                                      ],
                                    ),
                            ),
                          );
                        },
                      );
                    } else {
                      content = Text(text);
                    }

                    final timeLabel = createdAt == null
                        ? ''
                        : _formatTime(createdAt.toDate());

                    final maxBubbleWidth =
                        MediaQuery.of(context).size.width * 0.7;

                    final bubbleTextStyle = TextStyle(
                      color: isMe ? Colors.white : (isDark ? Colors.white : Colors.black87),
                    );

                        final isSeen = isMe &&
                            otherLastRead != null &&
                            createdAt != null &&
                            otherLastRead.toDate().isAfter(createdAt.toDate());

                        final currentDate = createdAt?.toDate();
                        final nextDate = index + 1 < docs.length
                            ? (docs[index + 1].data()
                                    as Map<String, dynamic>)['createdAt']
                                as Timestamp?
                            : null;
                        final showSeparator = currentDate != null &&
                            (nextDate == null ||
                                !_isSameDay(
                                  currentDate,
                                  nextDate.toDate(),
                                ));
                        final separatorLabel =
                            currentDate != null ? _formatDay(currentDate) : '';

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (showSeparator && separatorLabel.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                child: Center(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: separatorColor,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      separatorLabel,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: isDark ? Colors.white70 : Colors.black87,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            Align(
                              alignment: isMe
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  if (!isMe)
                                    CircleAvatar(
                                      radius: 14,
                                      backgroundColor: AppColors.primary,
                                      backgroundImage: senderAvatar != null
                                          ? NetworkImage(senderAvatar)
                                          : null,
                                      child: senderAvatar == null
                                          ? Text(
                                              senderName.toString().isNotEmpty
                                                  ? senderName[0].toUpperCase()
                                                  : '?',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                              ),
                                            )
                                          : null,
                                    ),
                                  if (!isMe) const SizedBox(width: 6),
                                  Flexible(
                                    child: ConstrainedBox(
                                      constraints: BoxConstraints(
                                          maxWidth: maxBubbleWidth),
                                      child: GestureDetector(
                                        onLongPress: () => _showMessageActions(
                                          messageId: messageId,
                                          isMe: isMe,
                                          text: text,
                                          senderName: senderName,
                                          replyTo: replyTo,
                                        ),
                                        child: Container(
                                          margin: const EdgeInsets.symmetric(
                                              vertical: 6),
                                          padding: const EdgeInsets.all(10),
                                          decoration: BoxDecoration(
                                            color: isMe
                                                ? bubbleMeColor
                                                : bubbleOtherColor,
                                            borderRadius:
                                                BorderRadius.circular(12),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.black
                                                    .withOpacity(0.05),
                                                blurRadius: 6,
                                                offset: const Offset(0, 2),
                                              ),
                                            ],
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              if (!isMe)
                                                Text(
                                                  senderName,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w600,
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              if (replyTo != null) ...[
                                                const SizedBox(height: 6),
                                                Container(
                                                  padding: const EdgeInsets.all(6),
                                                  decoration: BoxDecoration(
                                                    color: isDark ? Colors.white12 : Colors.black12,
                                                    borderRadius:
                                                        BorderRadius.circular(8),
                                                  ),
                                                  child: Text(
                                                    'Replying to ${replyTo['senderName'] ?? 'message'}: ${replyTo['text'] ?? ''}',
                                                    style: const TextStyle(
                                                        fontSize: 11),
                                                    softWrap: true,
                                                  ),
                                                ),
                                              ],
                                              const SizedBox(height: 4),
                                              DefaultTextStyle(
                                                style: bubbleTextStyle,
                                                child: _wrapMediaContent(
                                                    content, mediaUrl, mediaType),
                                              ),
                                              const SizedBox(height: 4),
                                              if (timeLabel.isNotEmpty)
                                                Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    Text(
                                                      timeLabel,
                                                      style: TextStyle(
                                                        fontSize: 10,
                                                        color: isMe ? Colors.white70 : (isDark ? Colors.white70 : AppColors.grey),
                                                      ),
                                                    ),
                                                    if (isMe) ...[
                                                      const SizedBox(width: 6),
                                                      Icon(
                                                        isSeen
                                                            ? Icons.done_all
                                                            : Icons.done,
                                                        size: 12,
                                                        color: isSeen
                                                            ? Colors.lightBlueAccent
                                                            : Colors.white70,
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                  },
                );
              },
            ),
          ),
          if (isOtherTyping)
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 4),
              child: Row(
                children: [
                  Text(
                    'typing�',
                    style: TextStyle(color: typingColor),
                  ),
                ],
              ),
            ),
          if (_replyingTo != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: replyBarColor,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Replying to ${_replyingTo?['senderName'] ?? 'message'}: ${_replyingTo?['text'] ?? ''}',
                      style: const TextStyle(fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () {
                      setState(() {
                        _replyingTo = null;
                      });
                    },
                  ),
                ],
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            color: Colors.white,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.photo),
                  onPressed: _sendingMedia
                      ? null
                      : () => _sendMedia(ImageSource.gallery, isVideo: false),
                ),
                IconButton(
                  icon: const Icon(Icons.videocam),
                  onPressed: _sendingMedia
                      ? null
                      : () => _sendMedia(ImageSource.gallery, isVideo: true),
                ),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      hintText: 'Message...',
                      border: InputBorder.none,
                    ),
                    onChanged: _handleTyping,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _sendingMedia ? null : _sendText,
                ),
              ],
            ),
          ),
          _quickEmojiRow(),
        ],
      ),
    );
      },
    );
  }

  Widget _quickEmojiRow() {
    const emojis = ['👍', '🔥', '😂', '😍', '🙏', '🎉'];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: Colors.white,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: emojis
            .map(
              (e) => InkWell(
                onTap: () {
                  _controller.text = '${_controller.text}$e';
                  _controller.selection = TextSelection.fromPosition(
                    TextPosition(offset: _controller.text.length),
                  );
                },
                child: Text(e, style: const TextStyle(fontSize: 18)),
              ),
            )
            .toList(),
      ),
    );
  }

  Future<void> _showMessageActions({
    required String messageId,
    required bool isMe,
    required String text,
    required String senderName,
    Map<String, dynamic>? replyTo,
  }) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.reply),
                title: const Text('Reply'),
                onTap: () => Navigator.pop(context, 'reply'),
              ),
              if (isMe) ...[
                ListTile(
                  leading: const Icon(Icons.edit),
                  title: const Text('Edit'),
                  onTap: () => Navigator.pop(context, 'edit'),
                ),
                ListTile(
                  leading: const Icon(Icons.delete),
                  title: const Text('Delete'),
                  onTap: () => Navigator.pop(context, 'delete'),
                ),
              ],
            ],
          ),
        );
      },
    );

    if (action == 'reply') {
      setState(() {
        _replyingTo = {
          'messageId': messageId,
          'text': text,
          'senderName': senderName,
        };
      });
    } else if (action == 'edit' && isMe) {
      final updated = await _showEditDialog(text);
      if (updated != null && updated.trim().isNotEmpty) {
        await _repo.editMessage(
          chatId: widget.chatId,
          messageId: messageId,
          text: updated.trim(),
        );
      }
    } else if (action == 'delete' && isMe) {
      await _repo.deleteMessage(
        chatId: widget.chatId,
        messageId: messageId,
      );
    }
  }

  Future<String?> _showEditDialog(String initial) async {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit message'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  String _formatDay(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(date.year, date.month, date.day);
    final diff = today.difference(target).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return DateFormat('MMM d, yyyy').format(date);
  }

  Widget _wrapMediaContent(
    Widget content,
    String? mediaUrl,
    String? mediaType,
  ) {
    if (mediaUrl != null && mediaType == 'image') {
      return InkWell(
        onTap: () => _showFullImage(mediaUrl),
        child: content,
      );
    }
    return content;
  }

  void _showFullImage(String url) {
    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          insetPadding: const EdgeInsets.all(12),
          backgroundColor: Colors.black,
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  child: Image.network(url, fit: BoxFit.contain),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _handleTyping(String value) {
    if (!_isTyping) {
      _isTyping = true;
      _setTyping(true);
    }
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 2), () {
      _isTyping = false;
      _setTyping(false);
    });
  }

  Future<void> _setTyping(bool value) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .update({
      'typing.${user.uid}': value,
    });
  }
}






