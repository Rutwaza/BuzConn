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
import 'package:media_store_plus/media_store_plus.dart';
import 'package:video_player/video_player.dart';
import 'video_call_page.dart';

import '../../../core/theme/colors.dart';
import '../../../core/services/supabase_storage_service.dart';
import '../../../data/repositories/chat_repository.dart';
import '../../../core/constants/app_constants.dart';

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
  List<_ChatMediaItem> _latestMediaItems = const [];
  StreamSubscription<DocumentSnapshot>? _callSub;
  bool _hasIncomingCall = false;
  bool _hasActiveCall = false;
  bool _incomingDialogShown = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      _repo.setLastRead(chatId: widget.chatId, userId: user.uid);
      _repo.setUserLastSeen(user.uid);
      _callSub = FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .collection('calls')
          .doc('active')
          .snapshots()
          .listen((snap) {
        if (!snap.exists || snap.data() == null) {
          if (mounted) {
            setState(() {
              _hasIncomingCall = false;
              _hasActiveCall = false;
              _incomingDialogShown = false;
            });
          }
          return;
        }
        final data = snap.data() as Map<String, dynamic>;
        final callerId = data['callerId'] as String?;
        final offer = data['offer'];
        final status = data['status'] as String?;
        final isIncoming =
            callerId != null && callerId != user.uid && offer != null;
        if (mounted) {
          setState(() {
            _hasIncomingCall = isIncoming;
            _hasActiveCall = status != 'ended';
            if (!isIncoming) {
              _incomingDialogShown = false;
            }
          });
        }
      });
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
    _callSub?.cancel();
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
    if (!isVideo) {
      final pickedImages = await picker.pickMultiImage();
      if (pickedImages.isEmpty) return;
      await _sendMultipleMediaFiles(
        userId: user.uid,
        files: pickedImages,
        mediaType: 'image',
      );
      return;
    }
    final pickedVideo = await picker.pickVideo(source: source);
    if (pickedVideo == null) return;
    await _sendMultipleMediaFiles(
      userId: user.uid,
      files: [pickedVideo],
      mediaType: 'video',
    );
  }

  Future<void> _sendMultipleMediaFiles({
    required String userId,
    required List<XFile> files,
    required String mediaType,
  }) async {
    setState(() {
      _sendingMedia = true;
    });
    try {
      await _setTyping(false);
      for (final file in files) {
        final bytes = await file.readAsBytes();
        final ext = mediaType == 'video' ? 'mp4' : 'jpg';
        final path =
            '$userId/${DateTime.now().millisecondsSinceEpoch}.$ext';
        final url = mediaType == 'video'
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
          continue;
        }
        await _repo.sendMessage(
          chatId: widget.chatId,
          senderId: userId,
          text: '',
          mediaUrl: url,
          mediaType: mediaType,
          replyTo: _replyingTo,
        );
      }
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
        final bubbleMeColor =
            const Color(0xFF0A86C2).withOpacity(0.7);
        final bubbleOtherColor = surfaceColor;
        final separatorColor = isDark ? Colors.white10 : Colors.black12;
        final replyBarColor = isDark ? const Color(0xFF1C212B) : AppColors.lightGrey;
        final inputBarColor = surfaceColor;
        final typingColor = isDark ? Colors.white70 : AppColors.grey;

        final showChatBg = isDark;
        final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
        final bgCacheWidth =
            (MediaQuery.of(context).size.width * devicePixelRatio).round();
        final bgCacheHeight =
            (MediaQuery.of(context).size.height * devicePixelRatio).round();

        if (_hasIncomingCall && !_incomingDialogShown) {
          _incomingDialogShown = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_hasIncomingCall) return;
            _showIncomingCallSheet(
              name: title,
              avatarUrl: avatarUrl,
            );
          });
        }
        return Scaffold(
          backgroundColor: backgroundColor,
          appBar: AppBar(
            scrolledUnderElevation: 0,
            titleSpacing: 10,
            title: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.22),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.grey.withValues(alpha: 0.35),
                    ),
                  ),
                  child: CircleAvatar(
                    radius: 18,
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
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          )
                        : null,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 2),
                      _ChatStatusLabel(
                        otherUserId: otherUserId,
                        isTyping: isOtherTyping,
                        chatType: chatType,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              _ChatActionButton(
                icon: Icons.call_rounded,
                onPressed: () => _showComingSoon('Audio calls'),
                tooltip: 'Audio call',
              ),
              const SizedBox(width: 6),
              _ChatActionButton(
                icon: Icons.videocam_rounded,
                onPressed: _startVideoCall,
                tooltip: 'Video call',
              ),
              PopupMenuButton<String>(
                icon: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.more_horiz_rounded,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                onSelected: (value) async {
                  if (value == 'profile') {
                    final businessId = chatData['businessId'] as String?;
                    if (businessId != null && context.mounted) {
                      context.push(AppRoutes.businessProfilePath(businessId));
                    }
                  } else if (value == 'media') {
                    if (_latestMediaItems.isNotEmpty) {
                      _openMediaViewer(
                        items: _latestMediaItems,
                        initialIndex: 0,
                      );
                    } else if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('No media yet'),
                        ),
                      );
                    }
                  } else if (value == 'join') {
                    _joinVideoCall();
                  } else if (value == 'clear') {
                    final confirmed = await _confirmClearChat();
                    if (confirmed) {
                      try {
                        await _repo.clearChatMessages(widget.chatId);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Chat cleared'),
                              backgroundColor: Colors.green,
                            ),
                          );
                        }
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Clear failed: $e')),
                          );
                        }
                      }
                    }
                  }
                },
                itemBuilder: (context) {
                  final items = <PopupMenuEntry<String>>[];
                  if (chatType != 'direct' &&
                      !isBusinessOwner &&
                      chatData['businessId'] != null) {
                    items.add(
                      const PopupMenuItem(
                        value: 'profile',
                        child: Text('View profile'),
                      ),
                    );
                  }
                  if (_hasIncomingCall || _hasActiveCall) {
                    items.add(
                      const PopupMenuItem(
                        value: 'join',
                        child: Text('Join call'),
                      ),
                    );
                  }
                  items.add(
                    const PopupMenuItem(
                      value: 'media',
                      child: Text('Media'),
                    ),
                  );
                  items.add(
                    const PopupMenuItem(
                      value: 'clear',
                      child: Text('Clear chat'),
                    ),
                  );
                  return items;
                },
              ),
            ],
          ),
          body: Stack(
            children: [
              if (showChatBg)
                Positioned.fill(
                  child: RepaintBoundary(
                    child: Opacity(
                      opacity: 0.65,
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
                      fallbackAvatarUrl: avatarUrl,
                    ),
                  ),
                  if (isOtherTyping)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.08)
                                : Colors.black.withValues(alpha: 0.04),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.08)
                                  : Colors.black.withValues(alpha: 0.05),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _TypingDots(color: typingColor),
                              const SizedBox(width: 8),
                              Text(
                                'typing...',
                                style: TextStyle(
                                  color: typingColor,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (_replyingTo != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: replyBarColor.withValues(alpha: 0.95),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: AppColors.primary.withValues(alpha: 0.18),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 4,
                              height: 28,
                              decoration: BoxDecoration(
                                color: AppColors.primary,
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Replying to ${_replyingTo?['senderName'] ?? 'message'}: ${_replyingTo?['text'] ?? ''}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close_rounded, size: 18),
                              onPressed: () {
                                setState(() {
                                  _replyingTo = null;
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: inputBarColor.withValues(alpha: 0.98),
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.10)
                                : Colors.black.withValues(alpha: 0.05),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: isDark ? 0.18 : 0.07),
                              blurRadius: 18,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            _ComposerIconButton(
                              icon: Icons.add_rounded,
                              onPressed:
                                  _sendingMedia ? null : _showAttachmentSheet,
                            ),
                            _ComposerIconButton(
                              icon:
                                  _isRecording ? Icons.stop_rounded : Icons.mic_none_rounded,
                              color: _isRecording ? Colors.redAccent : null,
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
                                    _ComposerIconButton(
                                      icon: _isRecordingPaused
                                          ? Icons.play_arrow_rounded
                                          : Icons.pause_rounded,
                                      onPressed: _togglePauseRecording,
                                    ),
                                  if (_recordedPath != null && !_isRecording)
                                    _ComposerIconButton(
                                      icon: _isVoicePlaying
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                      onPressed: _togglePlayRecording,
                                    ),
                                  if (_recordedPath != null && !_isRecording)
                                    _ComposerIconButton(
                                      icon: Icons.delete_outline_rounded,
                                      onPressed: _discardRecording,
                                    ),
                                ],
                              ),
                            Expanded(
                              child: (_isRecording || _recordedPath != null)
                                  ? Row(
                                      children: [
                                        const SizedBox(width: 6),
                                        Icon(
                                          Icons.fiber_manual_record,
                                          size: 14,
                                          color: _isRecording
                                              ? Colors.redAccent
                                              : Colors.orangeAccent,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          _isRecording
                                              ? (_isRecordingPaused
                                                  ? 'Recording paused...'
                                                  : 'Recording...')
                                              : 'Voice note ready',
                                          style: TextStyle(
                                            color: isDark
                                                ? Colors.white70
                                                : Colors.black54,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    )
                                  : TextField(
                                      controller: _controller,
                                      style: TextStyle(
                                        color: isDark
                                            ? Colors.white
                                            : Colors.black87,
                                      ),
                                      decoration: InputDecoration(
                                        hintText: 'Message your people...',
                                        hintStyle: TextStyle(
                                          color: isDark
                                              ? Colors.white54
                                              : AppColors.grey,
                                        ),
                                        border: InputBorder.none,
                                      ),
                                      onChanged: _handleTyping,
                                    ),
                            ),
                            Container(
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    AppColors.primary,
                                    AppColors.primary.withValues(alpha: 0.78),
                                  ],
                                ),
                                shape: BoxShape.circle,
                              ),
                              child: IconButton(
                                icon: const Icon(
                                  Icons.send_rounded,
                                  color: Colors.white,
                                  size: 20,
                                ),
                                onPressed: _sendingMedia
                                    ? null
                                    : _isRecording
                                        ? null
                                        : (_recordedPath != null
                                            ? _sendRecordedAudio
                                            : _sendText),
                              ),
                            ),
                          ],
                        ),
                      ),
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
    String? fallbackAvatarUrl,
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

        final mediaItems = <_ChatMediaItem>[];
        for (final doc in docs) {
          final data = doc.data() as Map<String, dynamic>;
          final mediaUrl = data['mediaUrl'] as String?;
          final mediaType = data['mediaType'] as String?;
          if (mediaUrl != null &&
              (mediaType == 'image' || mediaType == 'video')) {
            mediaItems.add(
              _ChatMediaItem(
                url: mediaUrl,
                type: mediaType!,
              ),
            );
          }
        }

        if (mediaItems.isNotEmpty) {
          _latestMediaItems = mediaItems;
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
            final isAudio = mediaUrl != null && mediaType == 'audio';
            final isEmojiOnly = _isEmojiOnly(text.toString()) &&
                mediaUrl == null &&
                replyTo == null;

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
              final index = mediaItems.indexWhere(
                (item) => item.url == mediaUrl,
              );
              content = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    onTap: () => _openMediaViewer(
                      items: mediaItems,
                      initialIndex: index < 0 ? 0 : index,
                    ),
                    child: Image.network(mediaUrl, width: 200),
                  ),
                  const SizedBox(height: 6),
                  _downloadChip(
                    url: mediaUrl,
                    name: null,
                    isMe: isMe,
                    mediaType: 'image',
                  ),
                ],
              );
            } else if (mediaUrl != null && mediaType == 'audio') {
              content = _AudioMessageTile(url: mediaUrl, isMe: isMe);
            } else if (mediaUrl != null && mediaType == 'document') {
              final name = data['mediaName'] ?? 'Document';
              final size = data['mediaSize'] as int?;
              content = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
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
                  ),
                  const SizedBox(height: 6),
                  _downloadChip(
                    url: mediaUrl,
                    name: name.toString(),
                    isMe: isMe,
                    mediaType: 'document',
                  ),
                ],
              );
            } else if (mediaUrl != null && mediaType == 'video') {
              final index = mediaItems.indexWhere(
                (item) => item.url == mediaUrl,
              );
              content = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FutureBuilder<Uint8List?>(
                    future: _getVideoThumbnail(mediaUrl),
                    builder: (context, snap) {
                      final bytes = snap.data;
                      return InkWell(
                        onTap: () {
                          _openMediaViewer(
                            items: mediaItems,
                            initialIndex: index < 0 ? 0 : index,
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
                                      child:
                                          Icon(Icons.play_circle_fill, size: 36),
                                    ),
                                  ],
                                ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 6),
                  _downloadChip(
                    url: mediaUrl,
                    name: null,
                    isMe: isMe,
                    mediaType: 'video',
                  ),
                ],
              );
            } else if (mediaType == 'call') {
              content = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    text.toString().toLowerCase().contains('missed')
                        ? Icons.call_missed
                        : Icons.call_end,
                    size: 16,
                    color: isMe
                        ? Colors.white70
                        : Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(text.toString()),
                ],
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
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.08)
                                : Colors.black.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            separatorLabel,
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? Colors.white70 : Colors.black87,
                              fontWeight: FontWeight.w700,
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
                            backgroundImage: (senderAvatar != null ||
                                    (fallbackAvatarUrl != null &&
                                        fallbackAvatarUrl.isNotEmpty))
                                ? NetworkImage(
                                    senderAvatar ??
                                        fallbackAvatarUrl ??
                                        '',
                                  )
                                : null,
                            child: (senderAvatar == null &&
                                    (fallbackAvatarUrl == null ||
                                        fallbackAvatarUrl.isEmpty))
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
                              padding: (isLinkOnly || isAudio || isEmojiOnly)
                                  ? EdgeInsets.zero
                                  : const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: (isLinkOnly || isAudio || isEmojiOnly)
                                    ? Colors.transparent
                                    : (isMe
                                        ? bubbleMeColor
                                        : bubbleOtherColor),
                                borderRadius: BorderRadius.only(
                                  topLeft: const Radius.circular(22),
                                  topRight: const Radius.circular(22),
                                  bottomLeft: Radius.circular(isMe ? 22 : 8),
                                  bottomRight: Radius.circular(isMe ? 8 : 22),
                                ),
                                border: (isLinkOnly || isAudio || isEmojiOnly)
                                    ? null
                                    : Border.all(
                                        color: isMe
                                            ? Colors.white.withValues(alpha: 0.08)
                                            : (isDark
                                                ? Colors.white.withValues(alpha: 0.08)
                                                : Colors.black.withValues(alpha: 0.05)),
                                      ),
                                boxShadow: (isLinkOnly || isAudio || isEmojiOnly)
                                    ? const []
                                    : [
                                          BoxShadow(
                                            color: Colors.black.withValues(alpha: 0.08),
                                            blurRadius: 12,
                                            offset: const Offset(0, 6),
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
                                            color: Color(0xFF61D1ED),
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
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;

    setState(() {
      _sendingMedia = true;
    });
    try {
      await _setTyping(false);
      for (final file in result.files) {
        final bytes = file.bytes;
        if (bytes == null) continue;
        final ext = file.extension ?? 'bin';
        final path =
            '${user.uid}/${DateTime.now().millisecondsSinceEpoch}.$ext';
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
          continue;
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
      }
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

  bool _isEmojiOnly(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    final emojiRegex = RegExp(
      r'^[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{200D}\s]+$',
      unicode: true,
    );
    return emojiRegex.hasMatch(trimmed);
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

  Widget _downloadChip({
    required String url,
    required String? name,
    required bool isMe,
    required String mediaType,
  }) {
    final color = isMe ? Colors.white70 : Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: () => _downloadMedia(
        url: url,
        fileName: name,
        mediaType: mediaType,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.download, size: 16, color: color),
          const SizedBox(width: 4),
          Text(
            'Download',
            style: TextStyle(fontSize: 12, color: color),
          ),
        ],
      ),
    );
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

  Future<bool> _confirmClearChat() async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Clear chat'),
            content: const Text(
              'This will delete all messages in this chat. Continue?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Clear'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _downloadMedia({
    required String url,
    String? fileName,
    required String mediaType,
  }) async {
    try {
      final fallbackName =
          'file_${DateTime.now().millisecondsSinceEpoch}';
      final segments = Uri.parse(url).pathSegments;
      final derivedName =
          segments.isNotEmpty ? segments.last : fallbackName;
      final safeName = (fileName == null || fileName.trim().isEmpty)
          ? derivedName
          : fileName;

      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/$safeName');
      final request = await HttpClient().getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw Exception('Download failed (${response.statusCode})');
      }
      await response.pipe(tempFile.openWrite());

      if (Platform.isAndroid) {
        MediaStore.appFolder = 'BusinessFinder';
        await MediaStore.ensureInitialized();
        final dirType = mediaType == 'image'
            ? DirType.photo
            : mediaType == 'video'
                ? DirType.video
                : DirType.download;
        final dirName = mediaType == 'image'
            ? DirName.pictures
            : mediaType == 'video'
                ? DirName.movies
                : DirName.download;
        await MediaStore().saveFile(
          tempFilePath: tempFile.path,
          dirType: dirType,
          dirName: dirName,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Saved to gallery/downloads'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Download saved to app storage'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed: $e')),
        );
      }
    }
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
    return content;
  }

  void _openMediaViewer({
    required List<_ChatMediaItem> items,
    required int initialIndex,
  }) {
    if (items.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ChatMediaViewerPage(
          items: items,
          initialIndex: initialIndex,
        ),
      ),
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

  void _startVideoCall() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoCallPage(
          chatId: widget.chatId,
          isCaller: true,
        ),
      ),
    );
  }

  void _joinVideoCall() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoCallPage(
          chatId: widget.chatId,
          isCaller: false,
        ),
      ),
    );
  }

  Future<void> _declineCall() async {
    final callDoc = FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .collection('calls')
        .doc('active');
    final callerCandidates = callDoc.collection('callerCandidates');
    final calleeCandidates = callDoc.collection('calleeCandidates');
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await _repo.sendMessage(
          chatId: widget.chatId,
          senderId: user.uid,
          text: 'Missed call',
          mediaType: 'call',
          replyTo: null,
        );
      }
      final batch = FirebaseFirestore.instance.batch();
      final callerSnap = await callerCandidates.get();
      for (final doc in callerSnap.docs) {
        batch.delete(doc.reference);
      }
      final calleeSnap = await calleeCandidates.get();
      for (final doc in calleeSnap.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();
      await callDoc.delete();
    } catch (_) {}
  }

  void _showIncomingCallSheet({
    required String name,
    String? avatarUrl,
  }) {
    showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF121826),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Incoming video call',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 12),
              CircleAvatar(
                radius: 28,
                backgroundColor: AppColors.primary,
                backgroundImage:
                    avatarUrl != null ? NetworkImage(avatarUrl) : null,
                child: avatarUrl == null
                    ? Text(
                        name.isNotEmpty ? name[0].toUpperCase() : '?',
                        style: const TextStyle(color: Colors.white),
                      )
                    : null,
              ),
              const SizedBox(height: 12),
              Text(
                name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        Navigator.of(context).pop();
                        await _declineCall();
                      },
                      icon: const Icon(Icons.call_end, color: Colors.red),
                      label: const Text(
                        'Decline',
                        style: TextStyle(color: Colors.red),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.red),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        _joinVideoCall();
                      },
                      icon: const Icon(Icons.videocam),
                      label: const Text('Answer'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ChatMediaItem {
  final String url;
  final String type; // image | video

  const _ChatMediaItem({
    required this.url,
    required this.type,
  });
}

class _ChatMediaViewerPage extends StatefulWidget {
  const _ChatMediaViewerPage({
    required this.items,
    required this.initialIndex,
  });

  final List<_ChatMediaItem> items;
  final int initialIndex;

  @override
  State<_ChatMediaViewerPage> createState() => _ChatMediaViewerPageState();
}

class _ChatMediaViewerPageState extends State<_ChatMediaViewerPage> {
  late final PageController _controller;
  int _index = 0;
  VideoPlayerController? _videoController;
  String? _currentVideoUrl;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.items.length - 1);
    _controller = PageController(initialPage: _index);
    _initForIndex(_index);
  }

  @override
  void dispose() {
    _controller.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  void _initForIndex(int index) {
    final item = widget.items[index];
    if (item.type != 'video') {
      _videoController?.pause();
      _videoController?.dispose();
      _videoController = null;
      _currentVideoUrl = null;
      return;
    }
    if (_currentVideoUrl == item.url) return;
    _videoController?.dispose();
    final controller =
        VideoPlayerController.networkUrl(Uri.parse(item.url));
    _videoController = controller;
    _currentVideoUrl = item.url;
    controller.initialize().then((_) {
      if (mounted) {
        setState(() {});
        controller.play();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _controller,
              itemCount: items.length,
              onPageChanged: (value) {
                setState(() => _index = value);
                _initForIndex(value);
              },
              itemBuilder: (context, index) {
                final item = items[index];
                if (item.type == 'image') {
                  return InteractiveViewer(
                    child: Center(
                      child: Image.network(item.url, fit: BoxFit.contain),
                    ),
                  );
                }
                final controller = _videoController;
                if (controller == null || !controller.value.isInitialized) {
                  return const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  );
                }
                return Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: controller.value.aspectRatio,
                          child: VideoPlayer(controller),
                        ),
                      ),
                    ),
                    VideoProgressIndicator(
                      controller,
                      allowScrubbing: true,
                      colors: const VideoProgressColors(
                        playedColor: Colors.white,
                        bufferedColor: Colors.white24,
                        backgroundColor: Colors.white10,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            icon: Icon(
                              controller.value.isPlaying
                                  ? Icons.pause
                                  : Icons.play_arrow,
                              color: Colors.white,
                            ),
                            onPressed: () {
                              controller.value.isPlaying
                                  ? controller.pause()
                                  : controller.play();
                              setState(() {});
                            },
                          ),
                          const Spacer(),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          SizedBox(
            height: 90,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final item = items[i];
                final isActive = i == _index;
                return GestureDetector(
                  onTap: () {
                    _controller.animateToPage(
                      i,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                    );
                    setState(() => _index = i);
                    _initForIndex(i);
                  },
                  child: Container(
                    width: 70,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: isActive ? Colors.white : Colors.white24,
                        width: isActive ? 2 : 1,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          item.type == 'image'
                              ? Image.network(item.url, fit: BoxFit.cover)
                              : FutureBuilder<Uint8List?>(
                                  future: VideoThumbnail.thumbnailData(
                                    video: item.url,
                                    imageFormat: ImageFormat.JPEG,
                                    maxWidth: 140,
                                    quality: 60,
                                  ),
                                  builder: (context, snap) {
                                    if (snap.data == null) {
                                      return const ColoredBox(
                                        color: Colors.black12,
                                        child: Center(
                                          child: Icon(
                                            Icons.play_arrow,
                                            color: Colors.white70,
                                          ),
                                        ),
                                      );
                                    }
                                    return Image.memory(
                                      snap.data!,
                                      fit: BoxFit.cover,
                                    );
                                  },
                                ),
                          if (item.type == 'video')
                            const Center(
                              child: Icon(
                                Icons.play_circle_fill,
                                color: Colors.white70,
                                size: 18,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}


class _ChatActionButton extends StatelessWidget {
  const _ChatActionButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05),
          shape: BoxShape.circle,
        ),
        child: IconButton(
          padding: EdgeInsets.zero,
          icon: Icon(icon, size: 18),
          onPressed: onPressed,
        ),
      ),
    );
  }
}

class _ComposerIconButton extends StatelessWidget {
  const _ComposerIconButton({
    required this.icon,
    required this.onPressed,
    this.color,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return IconButton(
      onPressed: onPressed,
      style: IconButton.styleFrom(
        minimumSize: const Size(38, 38),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.04),
      ),
      icon: Icon(icon, color: color),
    );
  }
}

class _ChatStatusLabel extends StatelessWidget {
  const _ChatStatusLabel({
    required this.otherUserId,
    required this.isTyping,
    required this.chatType,
  });

  final String? otherUserId;
  final bool isTyping;
  final String chatType;

  @override
  Widget build(BuildContext context) {
    if (isTyping) {
      return const Text(
        'typing...',
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: AppColors.primary,
        ),
      );
    }

    if (otherUserId == null || otherUserId!.isEmpty) {
      return Text(
        chatType == 'direct' ? 'Conversation' : 'Creator chat',
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.white70
              : AppColors.grey,
        ),
      );
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(otherUserId)
          .snapshots(),
      builder: (context, snapshot) {
        final lastSeen = snapshot.data?.data()?['lastSeen'] as Timestamp?;
        final isOnline = lastSeen != null &&
            DateTime.now().difference(lastSeen.toDate()).inMinutes < 3;
        final text = isOnline
            ? 'Active now'
            : lastSeen == null
                ? (chatType == 'direct' ? 'Offline' : 'Creator chat')
                : _formatActivity(lastSeen.toDate());
        final color = isOnline
            ? const Color(0xFF37C58A)
            : (Theme.of(context).brightness == Brightness.dark
                ? Colors.white70
                : AppColors.grey);
        return Text(
          text,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        );
      },
    );
  }

  static String _formatActivity(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 60) return 'Active ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return 'Active ${diff.inHours}h ago';
    return 'Active ${diff.inDays}d ago';
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
  final List<double> _waveHeights = const [
    6, 10, 14, 8, 16, 12, 6, 18, 9, 14, 8, 12, 6, 10, 7, 15
  ];

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
    final activeColor = widget.isMe
        ? Colors.white.withOpacity(0.95)
        : Theme.of(context).colorScheme.primary;
    final inactiveColor = widget.isMe
        ? Colors.white38
        : Theme.of(context).colorScheme.primary.withOpacity(0.35);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
          color: widget.isMe ? Colors.white : Theme.of(context).iconTheme.color,
          onPressed: _toggle,
        ),
        SizedBox(
          width: 140,
          height: 28,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(_waveHeights.length, (i) {
              final ratio = i / (_waveHeights.length - 1);
              final isActive = ratio <= progress;
              return Container(
                width: 4,
                height: _waveHeights[i],
                margin: const EdgeInsets.symmetric(horizontal: 1),
                decoration: BoxDecoration(
                  color: isActive ? activeColor : inactiveColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            }),
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


