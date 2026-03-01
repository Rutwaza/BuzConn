import 'dart:typed_data';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';

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
  final _messageKeys = <String, GlobalKey>{};
  final ScrollController _scrollController = ScrollController();
  final Map<String, int> _messageIndex = {};
  Map<String, dynamic>? _replyingTo;
  bool _sendingMedia = false;
  String? _lastReadMessageId;
  bool _isTyping = false;
  Timer? _typingTimer;
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _voicePlayer = AudioPlayer();
  bool _isRecording = false;
  bool _isRecordingPaused = false;
  bool _isVoicePlaying = false;
  String? _recordedPath;
  bool _showScrollToBottom = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
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
    _recorder.dispose();
    _voicePlayer.dispose();
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
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

        final showChatBg = isDark;
        final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
        final bgCacheWidth =
            (MediaQuery.of(context).size.width * devicePixelRatio).round();
        final bgCacheHeight =
            (MediaQuery.of(context).size.height * devicePixelRatio).round();
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
            actions: [
              IconButton(
                icon: const Icon(Icons.call),
                onPressed: () => _showComingSoon('Audio calls'),
                tooltip: 'Audio call',
              ),
              IconButton(
                icon: const Icon(Icons.videocam),
                onPressed: () => _showComingSoon('Video calls'),
                tooltip: 'Video call',
              ),
            ],
          ),
          body: Stack(
            children: [
              if (showChatBg)
                Positioned.fill(
                  child: RepaintBoundary(
                    child: Opacity(
                      opacity: 0.35,
                      child: Image.asset(
                        'assets/images/chat_bg.gif',
                        fit: BoxFit.cover,
                        alignment: Alignment.center,
                        filterQuality: FilterQuality.low,
                        gaplessPlayback: true,
                        cacheWidth: bgCacheWidth,
                        cacheHeight: bgCacheHeight,
                      ),
                    ),
                  ),
                ),
              Column(
                children: [
                  Expanded(
                    child: _buildMessagesList(
                      user: user,
                      otherLastRead: otherLastRead,
                      isDark: isDark,
                      bubbleMeColor: bubbleMeColor,
                      bubbleOtherColor: bubbleOtherColor,
                      separatorColor: separatorColor,
                      replyBarColor: replyBarColor,
                    ),
                  ),
                  if (isOtherTyping)
                    Padding(
                      padding: const EdgeInsets.only(left: 16, bottom: 4),
                      child: Row(
                        children: [
                          _TypingDots(color: typingColor),
                        ],
                      ),
                    ),
                  if (_replyingTo != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    color: inputBarColor,
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.attach_file),
                          onPressed: _sendingMedia ? null : _showAttachmentSheet,
                        ),
                        IconButton(
                          icon: Icon(
                            _isRecording ? Icons.stop_circle : Icons.mic,
                            color: _isRecording ? Colors.redAccent : null,
                          ),
                          onPressed: _sendingMedia
                              ? null
                              : () {
                                  if (_isRecording) {
                                    _stopRecording();
                                  } else {
                                    _startRecording();
                                  }
                                },
                        ),
                        if (_isRecording || _recordedPath != null)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_isRecording)
                                IconButton(
                                  icon: Icon(
                                    _isRecordingPaused
                                        ? Icons.play_arrow
                                        : Icons.pause,
                                  ),
                                  onPressed: _togglePauseRecording,
                                ),
                              if (_recordedPath != null && !_isRecording)
                                IconButton(
                                  icon: Icon(
                                    _isVoicePlaying
                                        ? Icons.pause
                                        : Icons.play_arrow,
                                  ),
                                  onPressed: _togglePlayRecording,
                                ),
                              if (_recordedPath != null && !_isRecording)
                                IconButton(
                                  icon: const Icon(Icons.send),
                                  onPressed: _sendRecordedAudio,
                                ),
                              if (_recordedPath != null && !_isRecording)
                                IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: _discardRecording,
                                ),
                            ],
                          ),
                        Expanded(
                          child: TextField(
                            controller: _controller,
                            style: TextStyle(
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Message...',
                              hintStyle: TextStyle(
                                color: isDark ? Colors.white54 : AppColors.grey,
                              ),
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
                ],
              ),
              if (_showScrollToBottom)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 78,
                  child: Center(
                    child: GestureDetector(
                      onTap: () {
                        if (_scrollController.hasClients) {
                          _scrollController.animateTo(
                            0,
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeOut,
                          );
                        }
                      },
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: isDark
                              ? Colors.white10
                              : Colors.black.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: isDark ? Colors.white24 : Colors.black12,
                          ),
                        ),
                        child: Icon(
                          Icons.keyboard_arrow_down,
                          color: isDark ? Colors.white70 : Colors.black54,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );

      },
    );
  }


  Widget _buildMessagesList({
    required User user,
    required Timestamp? otherLastRead,
    required bool isDark,
    required Color bubbleMeColor,
    required Color bubbleOtherColor,
    required Color separatorColor,
    required Color replyBarColor,
  }) {
    return StreamBuilder<QuerySnapshot>(
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
        _messageIndex.clear();
        for (var i = 0; i < docs.length; i++) {
          final data = docs[i].data() as Map<String, dynamic>;
          final id = data['id'] ?? docs[i].id;
          if (id != null) {
            _messageIndex[id.toString()] = i;
          }
        }

        return ListView.builder(
          controller: _scrollController,
          reverse: true,
          padding: const EdgeInsets.all(12),
          cacheExtent: 3000,
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
            final messageId = (data['id'] ?? doc.id).toString();
            _messageKeys.putIfAbsent(messageId, () => GlobalKey());
            final isLinkOnly = _isSingleUrl(text.toString());

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
            } else if (mediaUrl != null && mediaType == 'audio') {
              content = _AudioMessageTile(url: mediaUrl, isMe: isMe);
            } else if (mediaUrl != null && mediaType == 'document') {
              final name = data['mediaName'] ?? 'Document';
              final size = data['mediaSize'] as int?;
              content = InkWell(
                onTap: () => _openDocument(mediaUrl),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: replyBarColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.insert_drive_file),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (size != null)
                              Text(
                                _formatBytes(size),
                                style: const TextStyle(fontSize: 11),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
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
                              child: Icon(Icons.play_circle_fill, size: 36),
                            )
                          : Stack(
                              fit: StackFit.expand,
                              children: [
                                Image.memory(bytes, fit: BoxFit.cover),
                                const Center(
                                  child: Icon(Icons.play_circle_fill, size: 36),
                                ),
                              ],
                            ),
                    ),
                  );
                },
              );
            } else {
              content = _buildLinkifiedText(
                text.toString(),
                isMe: isMe,
                isDark: isDark,
              );
            }

            final timeLabel =
                createdAt == null ? '' : _formatTime(createdAt.toDate());

            final maxBubbleWidth = MediaQuery.of(context).size.width * 0.7;

            final bubbleTextStyle = TextStyle(
              color: isMe ? Colors.white : (isDark ? Colors.white : Colors.black87),
            );

            final isSeen = isMe &&
                otherLastRead != null &&
                createdAt != null &&
                otherLastRead.toDate().isAfter(createdAt.toDate());

            final currentDate = createdAt?.toDate();
            final nextDate = index + 1 < docs.length
                ? (docs[index + 1].data() as Map<String, dynamic>)['createdAt']
                    as Timestamp?
                : null;
            final showSeparator = currentDate != null &&
                (nextDate == null || !_isSameDay(currentDate, nextDate.toDate()));
            final separatorLabel =
                currentDate != null ? _formatDay(currentDate) : '';

            return KeyedSubtree(
              key: ValueKey(messageId),
              child: Column(
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
                    key: _messageKeys[messageId],
                    alignment:
                        isMe ? Alignment.centerRight : Alignment.centerLeft,
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
                            constraints:
                                BoxConstraints(maxWidth: maxBubbleWidth),
                            child: GestureDetector(
                              onLongPress: () => _showMessageActions(
                                messageId: messageId,
                                isMe: isMe,
                                text: text,
                                senderName: senderName,
                                replyTo: replyTo,
                              ),
                              child: Container(
                                margin:
                                    const EdgeInsets.symmetric(vertical: 6),
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: isLinkOnly
                                      ? Colors.transparent
                                      : (isMe
                                          ? bubbleMeColor
                                          : bubbleOtherColor),
                                  borderRadius: BorderRadius.circular(12),
                                  boxShadow: isLinkOnly
                                      ? const []
                                      : [
                                          BoxShadow(
                                            color:
                                                Colors.black.withOpacity(0.05),
                                            blurRadius: 6,
                                            offset: const Offset(0, 2),
                                          ),
                                        ],
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
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
                                      InkWell(
                                        onTap: () {
                                          final replyId =
                                              replyTo['messageId'] as String?;
                                          if (replyId != null) {
                                            _scrollToMessage(replyId);
                                          }
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.all(6),
                                          decoration: BoxDecoration(
                                            color: isDark
                                                ? Colors.white12
                                                : Colors.black12,
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                          child: Text(
                                            'Replying to ${replyTo['senderName'] ?? 'message'}: ${replyTo['text'] ?? ''}',
                                            style:
                                                const TextStyle(fontSize: 11),
                                            softWrap: true,
                                          ),
                                        ),
                                      ),
                                    ],
                                    const SizedBox(height: 4),
                                    DefaultTextStyle(
                                      style: bubbleTextStyle,
                                      child: _wrapMediaContent(
                                        content,
                                        mediaUrl,
                                        mediaType,
                                      ),
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
                                              color: isMe
                                                  ? Colors.white70
                                                  : (isDark
                                                      ? Colors.white70
                                                      : AppColors.grey),
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
              ),
            );
          },
        );
      },
    );
  }




  Future<void> _startRecording() async {
    if (_sendingMedia) return;
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission required.')),
        );
      }
      return;
    }

    final dir = await getTemporaryDirectory();
    final filePath =
        '${dir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 128000,
        sampleRate: 44100,
      ),
      path: filePath,
    );

    if (mounted) {
      setState(() {
        _isRecording = true;
        _isRecordingPaused = false;
        _recordedPath = null;
      });
    }
  }

  Future<void> _stopRecording() async {
    final path = await _recorder.stop();
    if (mounted) {
      setState(() {
        _isRecording = false;
        _isRecordingPaused = false;
        _recordedPath = path;
      });
    }
  }

  Future<void> _togglePauseRecording() async {
    if (!_isRecording) return;
    if (_isRecordingPaused) {
      await _recorder.resume();
    } else {
      await _recorder.pause();
    }
    if (mounted) {
      setState(() {
        _isRecordingPaused = !_isRecordingPaused;
      });
    }
  }

  Future<void> _togglePlayRecording() async {
    final path = _recordedPath;
    if (path == null) return;
    if (_isVoicePlaying) {
      await _voicePlayer.pause();
      if (mounted) setState(() => _isVoicePlaying = false);
      return;
    }
    await _voicePlayer.play(DeviceFileSource(path));
    if (mounted) {
      setState(() => _isVoicePlaying = true);
    }
    _voicePlayer.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _isVoicePlaying = false);
    });
  }

  Future<void> _sendRecordedAudio() async {
    final path = _recordedPath;
    if (path == null) return;
    await _sendAudio(path);
    if (mounted) {
      setState(() {
        _recordedPath = null;
        _isVoicePlaying = false;
      });
    }
  }

  void _discardRecording() {
    _voicePlayer.stop();
    final path = _recordedPath;
    if (path != null) {
      try {
        File(path).deleteSync();
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _recordedPath = null;
        _isVoicePlaying = false;
      });
    }
  }

  Future<void> _sendAudio(String path) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() {
      _sendingMedia = true;
    });
    try {
      await _setTyping(false);
      final bytes = await File(path).readAsBytes();
      final fileName = '${user.uid}/${DateTime.now().millisecondsSinceEpoch}.m4a';
      final url = await SupabaseStorageService.instance.uploadAudio(
        bucket: 'chat-media',
        path: fileName,
        bytes: bytes,
      );

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
        mediaType: 'audio',
        replyTo: _replyingTo,
      );
      setState(() {
        _replyingTo = null;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Voice note failed: $e')),
        );
      }
    } finally {
      try {
        File(path).deleteSync();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _sendingMedia = false;
        });
      }
    }
  }


  Future<void> _sendDocument() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        'pdf',
        'doc',
        'docx',
        'xls',
        'xlsx',
        'ppt',
        'pptx',
        'txt',
        'csv',
        'zip',
        'rar',
      ],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) return;

    setState(() {
      _sendingMedia = true;
    });
    try {
      await _setTyping(false);
      final ext = file.extension ?? 'bin';
      final path = '${user.uid}/${DateTime.now().millisecondsSinceEpoch}.$ext';
      final url = await SupabaseStorageService.instance.uploadFile(
        bucket: 'chat-media',
        path: path,
        bytes: bytes,
      );
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
        mediaType: 'document',
        mediaName: file.name,
        mediaSize: bytes.length,
        replyTo: _replyingTo,
      );
      setState(() {
        _replyingTo = null;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Document send failed: $e')),
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

  Future<void> _openDocument(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  String _formatBytes(int bytes) {
    const kb = 1024;
    const mb = kb * 1024;
    if (bytes >= mb) {
      return '${(bytes / mb).toStringAsFixed(1)} MB';
    }
    if (bytes >= kb) {
      return '${(bytes / kb).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }

  void _showComingSoon(String feature) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$feature coming soon!')),
    );
  }

  void _showAttachmentSheet() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.photo),
                title: const Text('Photo'),
                onTap: () {
                  Navigator.of(context).pop();
                  _sendMedia(ImageSource.gallery, isVideo: false);
                },
              ),
              ListTile(
                leading: const Icon(Icons.videocam),
                title: const Text('Video'),
                onTap: () {
                  Navigator.of(context).pop();
                  _sendMedia(ImageSource.gallery, isVideo: true);
                },
              ),
              ListTile(
                leading: const Icon(Icons.insert_drive_file),
                title: const Text('Document'),
                onTap: () {
                  Navigator.of(context).pop();
                  _sendDocument();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _scrollToMessage(String messageId) async {
    final key = _messageKeys[messageId];
    final ctx = key?.currentContext;
    if (ctx != null) {
      await Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        alignment: 0.5,
        curve: Curves.easeOut,
      );
      return;
    }

    final index = _messageIndex[messageId];
    if (index == null || !_scrollController.hasClients) return;
    final approxOffset = (index * 84.0)
        .clamp(0.0, _scrollController.position.maxScrollExtent);
    await _scrollController.animateTo(
      approxOffset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
    await Future.delayed(const Duration(milliseconds: 60));
    final ctxAfter = _messageKeys[messageId]?.currentContext;
    if (ctxAfter != null) {
      await Scrollable.ensureVisible(
        ctxAfter,
        duration: const Duration(milliseconds: 250),
        alignment: 0.5,
        curve: Curves.easeOut,
      );
    }
  }

  Widget _buildLinkifiedText(
    String text, {
    required bool isMe,
    required bool isDark,
  }) {
    final linkStyle = TextStyle(
      color: isMe ? Colors.lightBlueAccent : Colors.blue,
      decoration: TextDecoration.none,
    );
    final normalStyle = TextStyle(
      color: isMe ? Colors.white : (isDark ? Colors.white : Colors.black87),
    );

    final spans = <TextSpan>[];
    final regex = RegExp(r'(https?:\/\/[^\s]+)');
    int start = 0;
    for (final match in regex.allMatches(text)) {
      if (match.start > start) {
        spans.add(TextSpan(
          text: text.substring(start, match.start),
          style: normalStyle,
        ));
      }
      final url = match.group(0)!;
      spans.add(TextSpan(
        text: url,
        style: linkStyle,
        recognizer: TapGestureRecognizer()
          ..onTap = () => _openLink(url),
      ));
      start = match.end;
    }
    if (start < text.length) {
      spans.add(TextSpan(
        text: text.substring(start),
        style: normalStyle,
      ));
    }
    if (spans.isEmpty) {
      return Text(text, style: normalStyle);
    }
    return RichText(text: TextSpan(children: spans));
  }

  bool _isSingleUrl(String text) {
    final trimmed = text.trim();
    final regex = RegExp(r'^(https?:\/\/[^\s]+)$');
    return regex.hasMatch(trimmed);
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) return;
    final shouldShow = _scrollController.offset > 220;
    if (shouldShow != _showScrollToBottom) {
      setState(() {
        _showScrollToBottom = shouldShow;
      });
    }
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (await canLaunchUrl(uri)) {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No app found to open this link.')),
      );
    }
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


class _AudioMessageTile extends StatefulWidget {
  const _AudioMessageTile({required this.url, required this.isMe});

  final String url;
  final bool isMe;

  @override
  State<_AudioMessageTile> createState() => _AudioMessageTileState();
}

class _AudioMessageTileState extends State<_AudioMessageTile> {
  final AudioPlayer _player = AudioPlayer();
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player.onDurationChanged.listen((d) {
      if (mounted) {
        setState(() => _duration = d);
      }
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) {
        setState(() => _position = p);
      }
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _position = Duration.zero;
        });
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  String _format(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Future<void> _toggle() async {
    if (_isPlaying) {
      await _player.pause();
      if (mounted) {
        setState(() => _isPlaying = false);
      }
      return;
    }
    await _player.play(UrlSource(widget.url));
    if (mounted) {
      setState(() => _isPlaying = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _duration.inMilliseconds > 0
        ? _duration
        : const Duration(seconds: 1);
    final progress = _position.inMilliseconds / total.inMilliseconds;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
          color: widget.isMe ? Colors.white : Theme.of(context).iconTheme.color,
          onPressed: _toggle,
        ),
        SizedBox(
          width: 120,
          child: LinearProgressIndicator(
            value: progress.clamp(0.0, 1.0),
            backgroundColor: Colors.white12,
            valueColor: AlwaysStoppedAnimation<Color>(
              widget.isMe
                  ? Colors.white70
                  : Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${_format(_position)} / ${_format(_duration)}',
          style: const TextStyle(fontSize: 11),
        ),
      ],
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots({required this.color});

  final Color color;

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _opacity(double phase) {
    final value = math.sin((_controller.value * math.pi * 2) + phase);
    return 0.35 + 0.65 * ((value + 1) / 2);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          children: [
            _dot(_opacity(0)),
            const SizedBox(width: 4),
            _dot(_opacity(1.2)),
            const SizedBox(width: 4),
            _dot(_opacity(2.4)),
          ],
        );
      },
    );
  }

  Widget _dot(double opacity) {
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        color: widget.color.withOpacity(opacity),
        shape: BoxShape.circle,
      ),
    );
  }
}


