import 'package:businessfinder/core/widgets/emoji_picker.dart';
import 'group_pages.dart';
import 'package:businessfinder/features/share/share_post_sheet.dart';
import 'package:businessfinder/core/services/media_picker.dart';
import 'dart:async';
import 'package:businessfinder/features/moderation/moderation.dart';
import 'package:businessfinder/core/i18n/tr.dart';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
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
import 'package:video_player/video_player.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'video_call_page.dart';
import 'location_map_page.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:businessfinder/features/chat/data/live_location_service.dart';

import '../../../core/theme/colors.dart';
import '../../../core/services/r2_storage_service.dart';
import 'package:businessfinder/features/chat/data/chat_repository.dart';
import 'package:businessfinder/features/chat/data/presence_service.dart';
import 'package:businessfinder/features/chat/logic/chat_messages_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/app_constants.dart';
import 'package:businessfinder/core/widgets/app_toast.dart';

part 'widgets/chat_media_viewer.dart';
part 'widgets/ghost_message.dart';
part 'widgets/chat_small_widgets.dart';
part 'widgets/chat_shared_panel.dart';
part 'widgets/chat_location.dart';

class ChatPage extends ConsumerStatefulWidget {
  final String chatId;
  final bool embedded;

  /// Inbox (desktop): arrow to go back to the empty panel.
  final VoidCallback? onBack;

  const ChatPage({
    super.key,
    required this.chatId,
    this.embedded = false,
    this.onBack,
  });

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

const _senderColors = [
  Color(0xFF61D1ED),
  Color(0xFFFF8A65),
  Color(0xFF81C784),
  Color(0xFFBA68C8),
  Color(0xFFFFD54F),
  Color(0xFF4DB6AC),
  Color(0xFFF06292),
];

class _ChatPageState extends ConsumerState<ChatPage> {
  // "typing…" of the other person, from the Realtime Database.
  bool _isOtherTyping = false;
  String? _typingWatchUid;
  StreamSubscription<bool>? _typingSub;
  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>? _sharedItems;
  final _controller = TextEditingController();
  final _repo = ChatRepository();
  final _thumbCache = <String, Future<Uint8List?>>{};
  final _messageKeys = <String, GlobalKey>{};
  final ScrollController _scrollController = ScrollController();
  final Map<String, int> _messageIndex = {};
  Map<String, dynamic>? _replyingTo;
  bool _sendingMedia = false;
  double _mediaProgress = 0;
  String _mediaProgressLabel = '';
  bool _isGhostMode = true;
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
  final Set<String> _revealedReceivedGhostMessageIds = <String>{};
  List<_ChatMediaItem> _latestMediaItems = const [];
  StreamSubscription<DocumentSnapshot>? _callSub;
  bool _hasIncomingCall = false;
  String _incomingCallType = 'video';
  bool _hasActiveCall = false;
  bool _incomingDialogShown = false;
  bool _ringingIncomingCall = false;
  static const MethodChannel _privacyChannel =
      MethodChannel('spotlight/privacy');
  static const MethodChannel _callsChannel = MethodChannel('spotlight/calls');

  @override
  void initState() {
    super.initState();
    _setScreenPrivacy(true);
    _scrollController.addListener(_handleScroll);
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      unawaited(_loadGhostModeDefault(user.uid));
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
          if (_ringingIncomingCall) {
            _ringingIncomingCall = false;
            unawaited(_setCallRinging(false));
          }
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
        final isIncoming = callerId != null &&
            callerId != user.uid &&
            offer != null &&
            status == 'calling';
        if (mounted) {
          setState(() {
            _hasIncomingCall = isIncoming;
            _incomingCallType = (data['callType'] ?? 'video').toString();
            _hasActiveCall = status != 'ended';
            if (!isIncoming) {
              _incomingDialogShown = false;
            }
          });
        }
        if (isIncoming && !_ringingIncomingCall) {
          _ringingIncomingCall = true;
          unawaited(_setCallRinging(true));
        } else if (!isIncoming && _ringingIncomingCall) {
          _ringingIncomingCall = false;
          unawaited(_setCallRinging(false));
        }
      });
    }
  }

  Future<void> _loadGhostModeDefault(String userId) async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();
      if (!mounted) return;
      setState(() {
        _isGhostMode = snapshot.data()?['ghostModeDefault'] != false;
      });
    } catch (_) {
      // Keep the safe default when preferences are unavailable.
    }
  }

  Future<void> _setGhostMode(bool enabled) async {
    setState(() => _isGhostMode = enabled);
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return;
    try {
      await FirebaseFirestore.instance.collection('users').doc(userId).set({
        'ghostModeDefault': enabled,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (error) {
      if (!mounted) return;
      showToast(context, 'Could not save ghost mode preference: $error');
    }
  }

  Future<void> _respondToIncomingRequest({
    required String userId,
    required bool accept,
  }) async {
    try {
      await _repo.respondToMessageRequest(
        chatId: widget.chatId,
        userId: userId,
        accept: accept,
      );
    } catch (error) {
      if (!mounted) return;
      showToast(context, 'Could not update request: $error');
    }
  }

  @override
  void dispose() {
    _setScreenPrivacy(false);
    _controller.dispose();
    _typingTimer?.cancel();
    _setTyping(false);
    _typingSub?.cancel();
    _recorder.dispose();
    _voicePlayer.dispose();
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    _callSub?.cancel();
    if (_ringingIncomingCall) {
      unawaited(_setCallRinging(false));
    }
    super.dispose();
  }

  Future<void> _setScreenPrivacy(bool enabled) async {
    if (!Platform.isAndroid && !Platform.isWindows) return;
    try {
      await _privacyChannel.invokeMethod<void>(
        'setSecureScreen',
        {'enabled': enabled},
      );
    } catch (_) {
      // Privacy flag support is best-effort on nonstandard Android shells.
    }
  }

  Future<void> _setCallRinging(bool enabled) async {
    if (Platform.isWindows) {
      try {
        await _callsChannel.invokeMethod<void>(
          'setRinging',
          {'enabled': enabled},
        );
      } catch (_) {}
      return;
    }
    if (!Platform.isAndroid) return;
    try {
      await _callsChannel.invokeMethod<void>(
        enabled ? 'startRinging' : 'stopRinging',
      );
    } catch (_) {}
  }

  Future<void> _sendText() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _sendingMedia || _isRecording) {
      return;
    }

    final text = _controller.text.trim();
    if (text.isEmpty) return;

    final replyTo = _replyingTo;
    final ghostNonce = _isGhostMode ? _ghostNonce() : null;
    final ghostCipherText = _isGhostMode
        ? _encodeGhostText(
            text,
            chatId: widget.chatId,
            senderId: user.uid,
            nonce: ghostNonce!,
          )
        : null;
    _typingTimer?.cancel();
    _isTyping = false;

    // Phase 2: the message shows at once (Firestore puts the write in the
    // list immediately), so we don't wait for the server. The composer is
    // free for the next message straight away. If the server refuses, we put
    // the text back and say so.
    setState(() => _replyingTo = null);
    _controller.clear();
    unawaited(_setTyping(false));
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }

    unawaited(
      _repo
          .sendMessage(
        chatId: widget.chatId,
        senderId: user.uid,
        text: ghostCipherText ?? text,
        replyTo: replyTo,
        isGhost: _isGhostMode,
        ghostCipherText: ghostCipherText,
        ghostNonce: ghostNonce,
      )
          .catchError((Object e) {
        if (!mounted) return;
        if (_controller.text.isEmpty) {
          _controller.text = text;
          _controller.selection = TextSelection.collapsed(
            offset: _controller.text.length,
          );
          setState(() => _replyingTo = replyTo);
        }
        showToast(context, 'Message not sent: $e');
      }),
    );
  }

  Future<void> _showEmojiPicker() async {
    // Full picker with categories (lib/core/widgets/emoji_picker.dart).
    await showEmojiPicker(context, controller: _controller);
    if (mounted) setState(() {});
  }

  Future<void> _sendMedia(ImageSource source, {required bool isVideo}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (!isVideo) {
      final pickedImages = await MediaPicker.pickMultiImage();
      if (pickedImages.isEmpty) return;
      await _sendMultipleMediaFiles(
        userId: user.uid,
        files: pickedImages,
        mediaType: 'image',
      );
      return;
    }
    final pickedVideo = await MediaPicker.pickVideo(source: source);
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
      _mediaProgress = 0;
      _mediaProgressLabel =
          'Preparing ${files.length} ${mediaType == 'image' ? 'photo(s)' : 'video'}...';
    });
    try {
      await _setTyping(false);
      for (var fileIndex = 0; fileIndex < files.length; fileIndex++) {
        final file = files[fileIndex];
        if (mounted) {
          setState(() {
            _mediaProgress = 0;
            _mediaProgressLabel = 'Sending ${fileIndex + 1} of ${files.length}';
          });
        }
        final bytes = await file.readAsBytes();
        final ext = mediaType == 'video' ? 'mp4' : 'jpg';
        final path = '$userId/${DateTime.now().millisecondsSinceEpoch}.$ext';
        final url = mediaType == 'video'
            ? await R2StorageService.instance.uploadVideo(
                bucket: 'chat-media',
                path: path,
                bytes: bytes,
                chatId: widget.chatId,
                onProgress: (progress) {
                  if (mounted) {
                    setState(() => _mediaProgress = progress);
                  }
                })
            : await R2StorageService.instance.uploadImage(
                bucket: 'chat-media',
                path: path,
                bytes: bytes,
                chatId: widget.chatId,
                onProgress: (progress) {
                  if (mounted) {
                    setState(() => _mediaProgress = progress);
                  }
                });

        if (url == null) {
          if (mounted) {
            showToast(context, tr('Upload failed. Try again.'));
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
        showToast(context, 'Media send failed: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _sendingMedia = false;
          _mediaProgress = 0;
          _mediaProgressLabel = '';
        });
      }
    }
  }

  Future<void> _downloadChatMedia({
    required String mediaRef,
    required String fileName,
  }) async {
    try {
      final url = await _resolveChatMediaUrl(mediaRef);
      final client = HttpClient();
      late List<int> bytes;
      try {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw HttpException('Download failed (${response.statusCode}).');
        }
        bytes = await response.fold<List<int>>(
          <int>[],
          (result, chunk) => result..addAll(chunk),
        );
      } finally {
        client.close(force: true);
      }
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save attachment',
        fileName: fileName,
        bytes: Uint8List.fromList(bytes),
      );
      if (savedPath == null || !mounted) return;
      showToast(context, 'Saved to $savedPath');
    } catch (error) {
      if (!mounted) return;
      showToast(context, 'Could not download file: $error');
    }
  }

  Future<Uint8List?> _getVideoThumbnail(String url) {
    return _thumbCache.putIfAbsent(
      url,
      () async {
        if (Platform.isWindows) {
          // VideoThumbnail doesn't work on Windows
          return null;
        }
        return VideoThumbnail.thumbnailData(
          video: url,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 420,
          quality: 70,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return Scaffold(body: Center(child: Text(tr('Please sign in.'))));
    }

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .snapshots(),
      builder: (context, chatSnap) {
        final chatData = chatSnap.data?.data() as Map<String, dynamic>? ?? {};
        final chatType = (chatData['chatType'] ?? '').toString();
        final requestStatus = (chatData['requestStatus'] ?? 'none').toString();
        final isIncomingMessageRequest = requestStatus == 'pending' &&
            chatData['requestRecipientId'] == user.uid;
        final isRejectedMessageRequest = requestStatus == 'rejected';
        final isBusinessOwner = chatData['businessOwnerId'] == user.uid;
        String title;
        String? avatarUrl;
        String? otherUserId;
        final isGroup = chatType == 'group';
        final groupMembers =
            (chatData['participants'] as List? ?? const []).length;
        final iAmGroupAdmin =
            (chatData['admins'] as List? ?? const []).contains(user.uid);
        final groupMuted =
            isGroup && chatData['onlyAdminsCanSend'] == true && !iAmGroupAdmin;
        if (isGroup) {
          title = (chatData['groupName'] ?? 'Group').toString();
          avatarUrl = chatData['groupImageUrl'] as String?;
          otherUserId = null;
        } else if (chatType == 'direct') {
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
        final otherLastRead = (chatData['lastReadAt']
            as Map<String, dynamic>?)?[otherUserId] as Timestamp?;
        _watchOtherTyping(otherUserId);
        final isOtherTyping = _isOtherTyping;

        final isDark = Theme.of(context).brightness == Brightness.dark;
        final backgroundColor =
            isDark ? const Color(0xFF0F1115) : const Color(0xFFF4F6FA);
        final surfaceColor = isDark ? const Color(0xFF151922) : Colors.white;
        final bubbleMeColor = const Color(0xFF0A86C2).withOpacity(0.7);
        final bubbleOtherColor = surfaceColor;
        final separatorColor = isDark ? Colors.white10 : Colors.black12;
        final replyBarColor =
            isDark ? const Color(0xFF1C212B) : AppColors.lightGrey;
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
        // Inside the inbox the chat gets the whole space (no side panel).
        final useDesktopSplitLayout =
            !widget.embedded && MediaQuery.of(context).size.width >= 1180;
        final appBar = AppBar(
          scrolledUnderElevation: 0,
          automaticallyImplyLeading: false,
          leading: widget.embedded && widget.onBack != null
              ? IconButton(
                  tooltip: tr('Back to inbox'),
                  onPressed: widget.onBack,
                  icon: const Icon(Icons.arrow_back_rounded),
                )
              : null,
          titleSpacing: widget.embedded && widget.onBack != null ? 0 : 10,
          title: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: !isGroup
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => GroupInfoPage(chatId: widget.chatId),
                    )),
            child: Row(
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
                    child: avatarUrl == null && isGroup
                        ? const Icon(Icons.groups_rounded,
                            color: Colors.white, size: 20)
                        : avatarUrl == null
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
                      if (isGroup)
                        Text(
                          '$groupMembers ${tr('members')} · ${tr('tap for group info')}',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.grey),
                        )
                      else
                        _ChatStatusLabel(
                          otherUserId: otherUserId,
                          isTyping: isOtherTyping,
                          chatType: chatType,
                        ),
                    ],
                  ),
                ),
                if (!isGroup)
                  IconButton(
                    tooltip: _isGhostMode ? 'Ghost mode on' : 'Ghost mode off',
                    onPressed: () => _setGhostMode(!_isGhostMode),
                    icon: Icon(
                      _isGhostMode ? Icons.visibility_off : Icons.visibility,
                      color: _isGhostMode ? AppColors.primary : Colors.grey,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            if (!isGroup) ...[
              _ChatActionButton(
                icon: Icons.call_rounded,
                onPressed: isIncomingMessageRequest || isRejectedMessageRequest
                    ? null
                    : _startAudioCall,
                tooltip: tr('Audio call'),
              ),
              const SizedBox(width: 6),
              _ChatActionButton(
                icon: Icons.videocam_rounded,
                onPressed: isIncomingMessageRequest || isRejectedMessageRequest
                    ? null
                    : _startVideoCall,
                tooltip: tr('Video call'),
              ),
            ],
            PopupMenuButton<String>(
              icon: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white10
                      : Colors.black.withValues(alpha: 0.05),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.more_horiz_rounded,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              onSelected: (value) async {
                if (value == 'group_info') {
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => GroupInfoPage(chatId: widget.chatId),
                  ));
                  return;
                }
                if (value == 'user_profile') {
                  if (otherUserId != null && otherUserId.isNotEmpty && context.mounted) {
                    context.push(AppRoutes.clientProfilePath(otherUserId));
                  }
                } else if (value == 'profile') {
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
                    showToast(context, tr('No media yet'));
                  }
                } else if (value == 'safety') {
                  if (otherUserId != null) {
                    await showUserSafetySheet(context,
                        userId: otherUserId,
                        name: tr('this person'),
                        reportType: 'chat',
                        reportId: widget.chatId);
                  }
                } else if (value == 'join') {
                  _joinVideoCall();
                } else if (value == 'clear') {
                  final confirmed = await _confirmClearChat();
                  if (confirmed) {
                    try {
                      await _repo.clearChatMessages(widget.chatId);
                      await ref
                          .read(chatMessagesProvider(widget.chatId))
                          .reloadAfterClear();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(tr('Chat cleared')),
                            backgroundColor: Colors.green,
                          ),
                        );
                      }
                    } catch (e) {
                      if (mounted) {
                        showToast(context, 'Clear failed: $e');
                      }
                    }
                  }
                }
              },
              itemBuilder: (context) {
                final items = <PopupMenuEntry<String>>[];
                if (isGroup) {
                  items.add(PopupMenuItem(
                    value: 'group_info',
                    child: Text(tr('Group info')),
                  ));
                }
                if (chatType != 'direct' &&
                    !isGroup &&
                    !isBusinessOwner &&
                    chatData['businessId'] != null) {
                  items.add(
                    PopupMenuItem(
                      value: 'profile',
                      child: Text(tr('View profile')),
                    ),
                  );
                }
                if (!isGroup &&
                    (chatType == 'direct' || isBusinessOwner) &&
                    otherUserId != null &&
                    otherUserId.isNotEmpty) {
                  items.add(PopupMenuItem(
                    value: 'user_profile',
                    child: Text(tr('View profile')),
                  ));
                }
                if (_hasIncomingCall || _hasActiveCall) {
                  items.add(
                    PopupMenuItem(
                      value: 'join',
                      child: Text(tr('Join call')),
                    ),
                  );
                }
                items.add(
                  PopupMenuItem(
                    value: 'media',
                    child: Text(tr('Media')),
                  ),
                );
                items.add(
                  PopupMenuItem(
                    value: 'clear',
                    child: Text(tr('Clear chat')),
                  ),
                );
                if (otherUserId != null && otherUserId.isNotEmpty) {
                  items.add(PopupMenuItem(
                    value: 'safety',
                    child: Text(tr('Report or block')),
                  ));
                }
                return items;
              },
            ),
          ],
        );
        final conversationPane = Stack(
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
                      errorBuilder: (context, error, stackTrace) {
                        // Fallback to a clean dark style if asset is not available
                        return Container(color: const Color(0xFF0F1115));
                      },
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
                              tr('typing...'),
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
                if (_sendingMedia)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _mediaProgressLabel.isEmpty
                                    ? 'Sending media...'
                                    : _mediaProgressLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            Text('${(_mediaProgress * 100).round()}%'),
                          ],
                        ),
                        const SizedBox(height: 5),
                        LinearProgressIndicator(value: _mediaProgress),
                      ],
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
                if (isIncomingMessageRequest)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: AppColors.primary.withValues(alpha: 0.25),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            tr('Message request'),
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            tr('Approve this request before replying or calling.'),
                            style: const TextStyle(color: AppColors.grey),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () => _respondToIncomingRequest(
                                    userId: user.uid,
                                    accept: false,
                                  ),
                                  icon: const Icon(Icons.close_rounded),
                                  label: Text(tr('Reject')),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: () => _respondToIncomingRequest(
                                    userId: user.uid,
                                    accept: true,
                                  ),
                                  icon: const Icon(Icons.check_rounded),
                                  label: Text(tr('Approve')),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  )
                else if (isRejectedMessageRequest)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                    child: Center(
                      child: Text(tr('This message request was declined.')),
                    ),
                  )
                else if (groupMuted)
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: inputBarColor,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(children: [
                          const Icon(Icons.campaign_outlined,
                              color: AppColors.grey),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                                tr('Only admins can send messages in this group.'),
                                style: const TextStyle(color: AppColors.grey)),
                          ),
                        ]),
                      ),
                    ),
                  )
                else
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
                              color: Colors.black
                                  .withValues(alpha: isDark ? 0.18 : 0.07),
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
                              icon: _isRecording
                                  ? Icons.stop_rounded
                                  : Icons.mic_none_rounded,
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
                                        hintText: tr('Encrypted message...'),
                                        hintStyle: TextStyle(
                                          color: isDark
                                              ? Colors.white54
                                              : AppColors.grey,
                                        ),
                                        border: InputBorder.none,
                                      ),
                                      textInputAction: TextInputAction.send,
                                      onSubmitted: (_) => _sendText(),
                                      onChanged: (value) {
                                        _handleTyping(value);
                                        if (mounted) {
                                          setState(() {});
                                        }
                                      },
                                    ),
                            ),
                            if (!_isRecording && _recordedPath == null)
                              _ComposerIconButton(
                                icon: Icons.emoji_emotions_outlined,
                                onPressed: _showEmojiPicker,
                              ),
                            Container(
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    const Color(0xFF61D1ED),
                                    const Color(0xFF7C4DFF)
                                        .withValues(alpha: 0.78),
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
        );

        final body = useDesktopSplitLayout
            ? Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      flex: 7,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(28),
                        child: conversationPane,
                      ),
                    ),
                    const SizedBox(width: 14),
                    SizedBox(
                      width: 320,
                      child: _buildDesktopDetailsPanel(
                        title: title,
                        avatarUrl: avatarUrl,
                        chatType: chatType,
                        isBusinessOwner: isBusinessOwner,
                        otherUserId: otherUserId,
                        chatData: chatData,
                        activityLabel: _ChatStatusLabel.statusText(
                          otherUserId: otherUserId,
                          isTyping: isOtherTyping,
                          chatType: chatType,
                        ),
                        isDark: isDark,
                      ),
                    ),
                  ],
                ),
              )
            : conversationPane;

        if (widget.embedded) {
          return ColoredBox(
            color: backgroundColor,
            child: Column(
              children: [
                SizedBox(
                  height: appBar.preferredSize.height,
                  child: MediaQuery.removePadding(
                    context: context,
                    removeTop: true,
                    child: appBar,
                  ),
                ),
                Expanded(child: body),
              ],
            ),
          );
        }

        return Scaffold(
          backgroundColor: backgroundColor,
          appBar: appBar,
          body: body,
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
    // One listener per chat, owned by ChatMessagesController (Phase 2).
    return Consumer(
      builder: (context, ref, _) {
        final messages = ref.watch(chatMessagesProvider(widget.chatId));
        final docs = messages.docs;
        if (messages.isLoading && docs.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        if (docs.isNotEmpty) {
          final latest = docs.first.data();
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
          final data = docs[i].data();
          final id = data['id'] ?? docs[i].id;
          if (id != null) {
            _messageIndex[id.toString()] = i;
          }
        }

        final mediaItems = <_ChatMediaItem>[];
        for (final doc in docs) {
          final data = doc.data();
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
          cacheExtent: 1500,
          // One extra row at the top for "loading older messages".
          itemCount: docs.length + (messages.hasMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index >= docs.length) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            final doc = docs[index];
            final isPending = doc.metadata.hasPendingWrites;
            final data = doc.data();
            final isMe = data['senderId'] == user.uid;
            final text = data['text'] ?? '';
            final isGhost = data['isGhost'] == true;
            final ghostCipherText = data['ghostCipherText'] as String?;
            final ghostNonce = data['ghostNonce'] as String?;
            final mediaUrl = data['mediaUrl'] as String?;
            final mediaType = data['mediaType'] as String?;
            final senderName = data['senderName'] ?? 'User';
            final senderAvatar = data['senderAvatar'] as String?;
            final createdAt = data['createdAt'] as Timestamp?;
            final rawReplyTo = data['replyTo'];
            final replyTo = rawReplyTo is Map
                ? Map<String, dynamic>.from(rawReplyTo)
                : null;
            final deleted = data['deleted'] == true;
            if (mediaType == 'system') {
              // "Alice added Bob" etc. (written by the server for groups).
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Center(
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 420),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : Colors.black.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      text.toString(),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white70 : Colors.black54,
                      ),
                    ),
                  ),
                ),
              );
            }
            final messageId = (data['id'] ?? doc.id).toString();
            _messageKeys.putIfAbsent(messageId, () => GlobalKey());
            final isLinkOnly = _isSingleUrl(text.toString());
            final isAudio = mediaUrl != null && mediaType == 'audio';
            final isVisual = !deleted &&
                mediaUrl != null &&
                (mediaType == 'image' || mediaType == 'video');
            final isEmojiOnly = !isGhost &&
                _isEmojiOnly(text.toString()) &&
                mediaUrl == null &&
                replyTo == null;

            Widget content;
            if (deleted) {
              content = Text(
                tr('Message deleted'),
                style: const TextStyle(
                  fontStyle: FontStyle.italic,
                  color: AppColors.grey,
                ),
              );
            } else if (isGhost) {
              // Decoded once per message, then cached by the controller.
              final decodedText = messages.ghostText(
                messageId,
                () => _decodeGhostText(
                  ghostCipherText ?? '',
                  chatId: widget.chatId,
                  senderId: data['senderId']?.toString() ?? '',
                  nonce: ghostNonce ?? '',
                ),
              );
              content = _GhostMessageContent(
                encryptedText: ghostCipherText ?? text.toString(),
                text: decodedText.isEmpty
                    ? 'Ghost message unavailable'
                    : decodedText,
                isMe: isMe,
                isDark: isDark,
                isEmojiOnly: _isEmojiOnly(decodedText),
                onReveal: isMe
                    ? null
                    : () {
                        _revealedReceivedGhostMessageIds.add(messageId);
                      },
                onHide: null,
              );
            } else if (data['sharedPost'] is Map) {
              // A post shared from the feed (share sheet).
              final shared =
                  Map<String, dynamic>.from(data['sharedPost'] as Map);
              final postId = (shared['postId'] ?? '').toString();
              content = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SharedPostBubble(
                    data: shared,
                    onOpen: () {
                      if (postId.isNotEmpty) {
                        context.push(AppRoutes.postPath(postId));
                      }
                    },
                  ),
                  if (data['shareNoteEmpty'] != true &&
                      text.toString().trim().isNotEmpty)
                    _buildLinkifiedText(text.toString(),
                        isMe: isMe, isDark: isDark),
                ],
              );
            } else if (mediaType == 'location' && data['location'] is Map) {
              // If you were sharing live and reopened the app, keep the pin moving.
              final info = LocationInfo.fromMessage(data);
              if (isMe &&
                  info.isLiveNow &&
                  !LiveLocationService.instance.isSharing(messageId)) {
                LiveLocationService.instance.start(
                  chatId: widget.chatId,
                  messageId: messageId,
                  until: info.until!,
                );
              }
              content = _LocationMessageCard(
                chatId: widget.chatId,
                messageId: messageId,
                data: data,
                isMe: isMe,
                isDark: isDark,
                senderName: senderName.toString(),
                senderAvatar: senderAvatar,
              );
            } else if (mediaUrl != null && mediaType == 'image') {
              final index = mediaItems.indexWhere(
                (item) => item.url == mediaUrl,
              );
              content = _ChatPhoto(
                resolve: () => _resolveChatMediaUrl(mediaUrl),
                onTap: () => _openMediaViewer(
                  items: mediaItems,
                  initialIndex: index < 0 ? 0 : index,
                ),
              );
            } else if (mediaUrl != null && mediaType == 'audio') {
              content = _AudioMessageTile(
                url: mediaUrl,
                chatId: widget.chatId,
                isMe: isMe,
              );
            } else if (mediaUrl != null && mediaType == 'document') {
              final name = data['mediaName'] ?? 'Document';
              final size = data['mediaSize'] as int?;
              content = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    onTap: () async {
                      try {
                        await _openLink(await _resolveChatMediaUrl(mediaUrl));
                      } catch (e) {
                        if (mounted) {
                          showToast(context, 'Could not open file: $e');
                        }
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: replyBarColor,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.lock_outline_rounded),
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
                                Text(
                                  size == null
                                      ? 'Tap to open private file'
                                      : '${_formatBytes(size)} · Tap to open',
                                  style: const TextStyle(fontSize: 11),
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
            } else if (mediaUrl != null && mediaType == 'video') {
              final index = mediaItems.indexWhere(
                (item) => item.url == mediaUrl,
              );
              content = _ChatVideoThumb(
                resolve: () => _resolveChatMediaUrl(mediaUrl),
                thumbnail: _getVideoThumbnail,
                onTap: () => _openMediaViewer(
                  items: mediaItems,
                  initialIndex: index < 0 ? 0 : index,
                ),
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
            } else if (isEmojiOnly) {
              final emojiCount = text.toString().trim().runes.length;
              final fontSize = emojiCount <= 2
                  ? 46.0
                  : emojiCount <= 5
                      ? 36.0
                      : 27.0;
              content = Text(
                text.toString(),
                style: TextStyle(fontSize: fontSize, height: 1.2),
              );
            } else {
              content = _buildLinkifiedText(
                text.toString(),
                isMe: isMe,
                isDark: isDark,
              );
            }

            if (!deleted &&
                mediaUrl != null &&
                mediaType != null &&
                const {'image', 'video', 'audio', 'document'}
                    .contains(mediaType)) {
              final mediaName = (data['mediaName'] ?? '').toString();
              final extension = switch (mediaType) {
                'image' => '.jpg',
                'video' => '.mp4',
                'audio' => '.m4a',
                _ => '',
              };
              final fileName = mediaName.isNotEmpty
                  ? mediaName
                  : 'Duhuze_${mediaType}_${doc.id}$extension';
              content = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  content,
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                        (mediaType == 'image' || mediaType == 'video') ? 8 : 0,
                        6,
                        0,
                        0),
                    child: _DownloadPill(
                      isMe: isMe,
                      onTap: () => _downloadChatMedia(
                        mediaRef: mediaUrl,
                        fileName: fileName,
                      ),
                    ),
                  ),
                ],
              );
            }

            // A just-sent message has no server time yet: show the phone's
            // time with a clock icon until the server confirms it.
            final timeLabel = createdAt == null
                ? (isPending ? _formatTime(DateTime.now()) : '')
                : _formatTime(createdAt.toDate());

            final maxBubbleWidth = MediaQuery.of(context).size.width * 0.7;

            final bubbleTextStyle = TextStyle(
              color: isMe
                  ? Colors.white
                  : (isDark ? Colors.white : Colors.black87),
            );

            final isSeen = isMe &&
                otherLastRead != null &&
                createdAt != null &&
                otherLastRead.toDate().isAfter(createdAt.toDate());

            final currentDate = createdAt?.toDate();
            final nextDate = index + 1 < docs.length
                ? docs[index + 1].data()['createdAt'] as Timestamp?
                : null;
            final showSeparator = currentDate != null &&
                (nextDate == null ||
                    !_isSameDay(currentDate, nextDate.toDate()));
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
                                    senderAvatar ?? fallbackAvatarUrl ?? '',
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
                                text: isGhost ? '[ghost message]' : text,
                                senderName: senderName,
                                replyTo: replyTo,
                              ),
                              child: Container(
                                margin: const EdgeInsets.symmetric(vertical: 6),
                                padding: (isLinkOnly || isAudio || isEmojiOnly)
                                    ? EdgeInsets.zero
                                    : isVisual
                                        ? const EdgeInsets.fromLTRB(3, 3, 3, 6)
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
                                              ? Colors.white
                                                  .withValues(alpha: 0.08)
                                              : (isDark
                                                  ? Colors.white
                                                      .withValues(alpha: 0.08)
                                                  : Colors.black
                                                      .withValues(alpha: 0.05)),
                                        ),
                                  boxShadow:
                                      (isLinkOnly || isAudio || isEmojiOnly)
                                          ? const []
                                          : [
                                              BoxShadow(
                                                color: Colors.black
                                                    .withValues(alpha: 0.08),
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
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12,
                                          // One colour per person (groups).
                                          color: _senderColors[
                                              data['senderId'].hashCode.abs() %
                                                  _senderColors.length],
                                        ),
                                      ),
                                    if (replyTo != null) ...[
                                      const SizedBox(height: 6),
                                      InkWell(
                                        onTap: () {
                                          final replyId =
                                              replyTo['messageId']?.toString();
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
                                              isPending
                                                  ? Icons.schedule
                                                  : isSeen
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
        showToast(context, tr('Microphone permission required.'));
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
      _mediaProgress = 0;
      _mediaProgressLabel = 'Uploading voice note...';
    });
    try {
      await _setTyping(false);
      final bytes = await File(path).readAsBytes();
      final fileName =
          '${user.uid}/${DateTime.now().millisecondsSinceEpoch}.m4a';
      final url = await R2StorageService.instance.uploadAudio(
        bucket: 'chat-media',
        path: fileName,
        bytes: bytes,
        chatId: widget.chatId,
        onProgress: (progress) {
          if (mounted) setState(() => _mediaProgress = progress);
        },
      );

      if (url == null) {
        if (mounted) {
          showToast(context, tr('Upload failed. Try again.'));
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
        showToast(context, 'Voice note failed: $e');
      }
    } finally {
      try {
        File(path).deleteSync();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _sendingMedia = false;
          _mediaProgress = 0;
          _mediaProgressLabel = '';
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
      _mediaProgress = 0;
      _mediaProgressLabel = 'Preparing ${result.files.length} file(s)...';
    });
    try {
      await _setTyping(false);
      for (var index = 0; index < result.files.length; index++) {
        final file = result.files[index];
        if (mounted) {
          setState(() {
            _mediaProgress = 0;
            _mediaProgressLabel =
                'Sending ${index + 1} of ${result.files.length}: ${file.name}';
          });
        }
        final bytes = file.bytes;
        if (bytes == null) continue;
        final ext = file.extension ?? 'bin';
        final path =
            '${user.uid}/${DateTime.now().millisecondsSinceEpoch}.$ext';
        final url = await R2StorageService.instance.uploadFile(
          bucket: 'chat-media',
          path: path,
          bytes: bytes,
          contentType: _contentTypeForFile(file.name),
          chatId: widget.chatId,
          onProgress: (progress) {
            if (mounted) setState(() => _mediaProgress = progress);
          },
        );
        if (url == null) {
          if (mounted) {
            showToast(context, tr('Upload failed. Try again.'));
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
        showToast(context, 'Document send failed: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _sendingMedia = false;
          _mediaProgress = 0;
          _mediaProgressLabel = '';
        });
      }
    }
  }

  String _contentTypeForFile(String fileName) {
    switch (fileName.split('.').last.toLowerCase()) {
      case 'pdf':
        return 'application/pdf';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls':
        return 'application/vnd.ms-excel';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'ppt':
        return 'application/vnd.ms-powerpoint';
      case 'pptx':
        return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      case 'txt':
        return 'text/plain';
      case 'csv':
        return 'text/csv';
      case 'zip':
        return 'application/zip';
      default:
        return 'application/octet-stream';
    }
  }

  Future<String> _resolveChatMediaUrl(String mediaRef) {
    return R2StorageService.instance.downloadPrivateMediaUrl(
      mediaRef: mediaRef,
      chatId: widget.chatId,
    );
  }

  Future<Map<String, String>> _loadRecipientProfileSummary({
    required String chatType,
    required bool isBusinessOwner,
    required String? otherUserId,
    required Map<String, dynamic> chatData,
  }) async {
    try {
      if (chatType == 'direct' || isBusinessOwner) {
        if (otherUserId == null || otherUserId.isEmpty) return const {};
        final snap = await FirebaseFirestore.instance
            .collection('users')
            .doc(otherUserId)
            .get();
        final data = snap.data() ?? const <String, dynamic>{};
        return {
          'subtitle': (data['userType'] ?? 'Member').toString(),
          'about': (data['bio'] ?? '').toString(),
          'phone': (data['phone'] ?? '').toString(),
          'email': (data['email'] ?? '').toString(),
          'location': (data['location'] ?? data['address'] ?? '').toString(),
        };
      }

      final businessId = (chatData['businessId'] ?? '').toString();
      if (businessId.isEmpty) return const {};
      final snap = await FirebaseFirestore.instance
          .collection('businesses')
          .doc(businessId)
          .get();
      final data = snap.data() ?? const <String, dynamic>{};
      return {
        'subtitle': (data['category'] ?? 'Business').toString(),
        'about': (data['description'] ?? data['bio'] ?? '').toString(),
        'phone': (data['phone'] ?? '').toString(),
        'email': (data['email'] ?? '').toString(),
        'location': (data['location'] ?? data['address'] ?? '').toString(),
      };
    } catch (_) {
      return const {};
    }
  }

  List<String> _extractLinks(String text) {
    final regex = RegExp(r'(https?:\/\/[^\s]+)', caseSensitive: false);
    return regex
        .allMatches(text)
        .map((match) => match.group(0) ?? '')
        .where((url) => url.isNotEmpty)
        .toList();
  }

  Widget _buildDesktopDetailsPanel({
    required String title,
    required String? avatarUrl,
    required String chatType,
    required bool isBusinessOwner,
    required String? otherUserId,
    required Map<String, dynamic> chatData,
    required String activityLabel,
    required bool isDark,
  }) {
    final cardColor = isDark ? const Color(0xFF121720) : Colors.white;
    final borderColor =
        isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.06);

    return DefaultTabController(
      length: 3,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: borderColor),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FutureBuilder<Map<String, String>>(
              future: _loadRecipientProfileSummary(
                chatType: chatType,
                isBusinessOwner: isBusinessOwner,
                otherUserId: otherUserId,
                chatData: chatData,
              ),
              builder: (context, snapshot) {
                final details = snapshot.data ?? const <String, String>{};
                final about = (details['about'] ?? '').trim();
                final profileRoute = chatType == 'direct' || isBusinessOwner
                    ? (otherUserId != null && otherUserId.isNotEmpty
                        ? AppRoutes.clientProfilePath(otherUserId)
                        : null)
                    : ((chatData['businessId'] as String?)?.isNotEmpty == true
                        ? AppRoutes.businessProfilePath(
                            (chatData['businessId'] as String?)!,
                          )
                        : null);

                return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: otherUserId != null && otherUserId.isNotEmpty
                      ? FirebaseFirestore.instance
                          .collection('users')
                          .doc(otherUserId)
                          .snapshots()
                      : const Stream.empty(),
                  builder: (context, userSnap) {
                    final lastSeen =
                        userSnap.data?.data()?['lastSeen'] as Timestamp?;
                    final isOnline = lastSeen != null &&
                        DateTime.now().difference(lastSeen.toDate()).inMinutes <
                            3;
                    final liveStatus = isOnline
                        ? 'Active now'
                        : lastSeen == null
                            ? 'Offline'
                            : _ChatStatusLabel._formatActivity(
                                lastSeen.toDate());

                    return Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: isDark
                              ? const [Color(0xFF1A2232), Color(0xFF121720)]
                              : const [Color(0xFFEAF7FF), Color(0xFFFFFFFF)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: AppColors.primary.withValues(alpha: 0.14),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Stack(
                                children: [
                                  CircleAvatar(
                                    radius: 28,
                                    backgroundColor: AppColors.primary,
                                    backgroundImage: avatarUrl != null &&
                                            avatarUrl.isNotEmpty
                                        ? NetworkImage(avatarUrl)
                                        : null,
                                    child:
                                        avatarUrl == null || avatarUrl.isEmpty
                                            ? Text(
                                                title.isNotEmpty
                                                    ? title[0].toUpperCase()
                                                    : '?',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.w800,
                                                  fontSize: 18,
                                                ),
                                              )
                                            : null,
                                  ),
                                  Positioned(
                                    right: 0,
                                    bottom: 0,
                                    child: Container(
                                      width: 14,
                                      height: 14,
                                      decoration: BoxDecoration(
                                        color: isOnline
                                            ? const Color(0xFF37C58A)
                                            : Colors.grey,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: isDark
                                              ? const Color(0xFF121720)
                                              : Colors.white,
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
                                    Text(
                                      title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 16,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      liveStatus,
                                      style: TextStyle(
                                        color: isOnline
                                            ? const Color(0xFF37C58A)
                                            : (isDark
                                                ? Colors.white70
                                                : AppColors.grey),
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            about.isNotEmpty
                                ? about
                                : 'Keep the conversation flowing and shared moments close.',
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isDark ? Colors.white70 : Colors.black87,
                              height: 1.35,
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: profileRoute == null
                                  ? null
                                  : () => context.push(profileRoute),
                              icon: const Icon(Icons.person_outline_rounded),
                              label: Text(tr('View profile')),
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                foregroundColor: Colors.white,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
            const SizedBox(height: 14),
            Container(
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.04)
                    : Colors.black.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(16),
              ),
              child: TabBar(
                dividerColor: Colors.transparent,
                indicator: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                labelColor: AppColors.primary,
                unselectedLabelColor: isDark ? Colors.white60 : AppColors.grey,
                tabs: const [
                  Tab(text: 'Media'),
                  Tab(text: 'Links'),
                  Tab(text: 'Docs'),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: FutureBuilder<
                  List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
                future: _sharedItems ??= ref
                    .read(chatMessagesProvider(widget.chatId))
                    .loadSharedItems(),
                builder: (context, snapshot) {
                  final docs = snapshot.data ?? const [];
                  final mediaEntries = <Map<String, dynamic>>[];
                  final linkEntries = <Map<String, dynamic>>[];
                  final documentEntries = <Map<String, dynamic>>[];

                  for (final doc in docs) {
                    final data = doc.data();
                    if (data['deleted'] == true) continue;

                    final messageId = (data['id'] ?? doc.id).toString();
                    final text = (data['text'] ?? '').toString().trim();
                    final mediaUrl = data['mediaUrl'] as String?;
                    final mediaType = data['mediaType'] as String?;

                    if (mediaUrl != null &&
                        (mediaType == 'image' || mediaType == 'video')) {
                      mediaEntries.add({
                        'messageId': messageId,
                        'url': mediaUrl,
                        'type': mediaType,
                      });
                    }

                    if (mediaUrl != null && mediaType == 'document') {
                      documentEntries.add({
                        'messageId': messageId,
                        'url': mediaUrl,
                        'name': (data['mediaName'] ?? 'Document').toString(),
                        'size': data['mediaSize'] as int?,
                      });
                    }

                    for (final link in _extractLinks(text)) {
                      final uri = Uri.tryParse(link);
                      linkEntries.add({
                        'messageId': messageId,
                        'url': link,
                        'host': (uri?.host ?? 'Shared link')
                            .replaceFirst('www.', ''),
                        'preview': text,
                      });
                    }
                  }

                  return TabBarView(
                    children: [
                      _buildSharedMediaGrid(mediaEntries, isDark),
                      _buildSharedLinksList(linkEntries, isDark),
                      _buildSharedDocumentsList(documentEntries, isDark),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _hardDeleteGhostMessage(String messageId) async {
    try {
      await _repo.hardDeleteMessage(
        chatId: widget.chatId,
        messageId: messageId,
      );
    } catch (e) {
      if (!mounted) return;
      showToast(context, 'Ghost message deletion failed: $e');
    }
  }

  void _deleteRevealedReceivedGhostMessages() {
    if (_revealedReceivedGhostMessageIds.isEmpty) return;
    final ids = List<String>.from(_revealedReceivedGhostMessageIds);
    _revealedReceivedGhostMessageIds.clear();
    for (final id in ids) {
      unawaited(_hardDeleteGhostMessage(id));
    }
  }

  String _ghostNonce() {
    final random = math.Random.secure();
    final bytes = List<int>.generate(12, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }

  String _encodeGhostText(
    String plainText, {
    required String chatId,
    required String senderId,
    required String nonce,
  }) {
    final plainBytes = utf8.encode(plainText);
    final cipherBytes = <int>[];
    for (var i = 0; i < plainBytes.length; i++) {
      final keyByte = _ghostKeyByte(
        index: i,
        chatId: chatId,
        senderId: senderId,
        nonce: nonce,
      );
      cipherBytes.add(plainBytes[i] ^ keyByte);
    }
    return base64UrlEncode(cipherBytes);
  }

  String _decodeGhostText(
    String cipherText, {
    required String chatId,
    required String senderId,
    required String nonce,
  }) {
    if (cipherText.isEmpty || nonce.isEmpty || senderId.isEmpty) return '';
    try {
      final cipherBytes = base64Url.decode(cipherText);
      final plainBytes = <int>[];
      for (var i = 0; i < cipherBytes.length; i++) {
        final keyByte = _ghostKeyByte(
          index: i,
          chatId: chatId,
          senderId: senderId,
          nonce: nonce,
        );
        plainBytes.add(cipherBytes[i] ^ keyByte);
      }
      return utf8.decode(plainBytes);
    } catch (_) {
      return '';
    }
  }

  int _ghostKeyByte({
    required int index,
    required String chatId,
    required String senderId,
    required String nonce,
  }) {
    final block = index ~/ 32;
    final digest = Hmac(
      sha256,
      utf8.encode('$chatId|$senderId|spotlight-ghost-v2'),
    ).convert(utf8.encode('$nonce|$block'));
    return digest.bytes[index % digest.bytes.length];
  }

  Future<void> _showLocationSheet() async {
    final choice = await showModalBottomSheet<Duration?>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        Widget live(String label, Duration d) => ListTile(
              leading: const Icon(Icons.share_location_rounded,
                  color: AppColors.secondary),
              title: Text('Share live location · $label'),
              onTap: () => Navigator.of(context).pop(d),
            );
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.my_location_rounded,
                    color: AppColors.primary),
                title: Text(tr('Send my current location')),
                onTap: () => Navigator.of(context).pop(Duration.zero),
              ),
              const Divider(height: 1),
              live('15 min', const Duration(minutes: 15)),
              live('1 hour', const Duration(hours: 1)),
              live('8 hours', const Duration(hours: 8)),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text(
                  tr('Live location moves while Duhuze is open. You can stop it any time.'),
                  style: const TextStyle(color: AppColors.grey, fontSize: 12),
                ),
              ),
            ],
          ),
        );
      },
    );
    if (choice == null || !mounted) return;
    await _sendLocation(liveFor: choice == Duration.zero ? null : choice);
  }

  Future<void> _sendLocation({Duration? liveFor}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(tr('Finding your location…')),
        duration: const Duration(seconds: 2),
      ),
    );
    try {
      final p = await LiveLocationService.currentPosition();
      if (!mounted) return;
      final replyTo = _replyingTo;
      setState(() => _replyingTo = null);
      final messageId = _repo.sendLocation(
        chatId: widget.chatId,
        senderId: user.uid,
        lat: p.latitude,
        lng: p.longitude,
        accuracy: p.accuracy,
        liveFor: liveFor,
        replyTo: replyTo,
        onUpload: (upload) => upload.catchError((Object e) {
          messenger.showSnackBar(
            SnackBar(content: Text('Location not sent: $e')),
          );
        }),
      );
      if (liveFor != null) {
        LiveLocationService.instance.start(
          chatId: widget.chatId,
          messageId: messageId,
          until: DateTime.now().add(liveFor),
        );
      }
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
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
                title: Text(tr('Photo')),
                onTap: () {
                  Navigator.of(context).pop();
                  _sendMedia(ImageSource.gallery, isVideo: false);
                },
              ),
              ListTile(
                leading: const Icon(Icons.videocam),
                title: Text(tr('Video')),
                onTap: () {
                  Navigator.of(context).pop();
                  _sendMedia(ImageSource.gallery, isVideo: true);
                },
              ),
              ListTile(
                leading: const Icon(Icons.insert_drive_file),
                title: Text(tr('Document')),
                onTap: () {
                  Navigator.of(context).pop();
                  _sendDocument();
                },
              ),
              ListTile(
                leading: const Icon(Icons.location_on_rounded,
                    color: AppColors.primary),
                title: Text(tr('Location')),
                subtitle: Text(tr('Send where you are, or share it live')),
                onTap: () {
                  Navigator.of(context).pop();
                  _showLocationSheet();
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
    final approxOffset =
        (index * 84.0).clamp(0.0, _scrollController.position.maxScrollExtent);
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
        recognizer: TapGestureRecognizer()..onTap = () => _openLink(url),
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
    // The list is reversed: the top (older messages) is maxScrollExtent.
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 400) {
      ref.read(chatMessagesProvider(widget.chatId)).loadMore();
    }
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
      showToast(context, tr('No app found to open this link.'));
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
                title: Text(tr('Reply')),
                onTap: () => Navigator.pop(context, 'reply'),
              ),
              if (isMe) ...[
                ListTile(
                  leading: const Icon(Icons.edit),
                  title: Text(tr('Edit')),
                  onTap: () => Navigator.pop(context, 'edit'),
                ),
                ListTile(
                  leading: const Icon(Icons.delete),
                  title: Text(tr('Delete')),
                  onTap: () => Navigator.pop(context, 'delete'),
                ),
              ],
            ],
          ),
        );
      },
    );

    if (!mounted) return;

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
        title: Text(tr('Edit message')),
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
            child: Text(tr('Cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(tr('Save')),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmClearChat() async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(tr('Clear chat')),
            content: Text(
              tr('Messages will be removed from this chat for you. The other person keeps their copy. Continue?'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(tr('Cancel')),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(tr('Clear')),
              ),
            ],
          ),
        ) ??
        false;
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

  Future<void> _openMediaViewer({
    required List<_ChatMediaItem> items,
    required int initialIndex,
  }) async {
    if (items.isEmpty) return;
    try {
      final resolvedItems = <_ChatMediaItem>[];
      for (final item in items) {
        resolvedItems.add(
          _ChatMediaItem(
            url: await _resolveChatMediaUrl(item.url),
            type: item.type,
          ),
        );
      }
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _ChatMediaViewerPage(
            items: resolvedItems,
            initialIndex: initialIndex,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        showToast(context, 'Could not open chat media: $e');
      }
    }
  }

  void _handleTyping(String value) {
    if (value.trim().isNotEmpty) {
      _deleteRevealedReceivedGhostMessages();
    }
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

  // Typing now goes to the Realtime Database (cheap, clears itself when the
  // phone disconnects) instead of writing the chat document every time.
  Future<void> _setTyping(bool value) =>
      PresenceService.instance.setTyping(widget.chatId, value);

  void _watchOtherTyping(String? otherUserId) {
    if (otherUserId == null || otherUserId == _typingWatchUid) return;
    _typingWatchUid = otherUserId;
    _typingSub?.cancel();
    _typingSub = PresenceService.instance
        .watchTyping(widget.chatId, otherUserId)
        .listen((typing) {
      if (mounted && typing != _isOtherTyping) {
        setState(() => _isOtherTyping = typing);
      }
    }, onError: (_) {});
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

  void _startAudioCall() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => VideoCallPage(
        chatId: widget.chatId,
        isCaller: true,
        audioOnly: true,
      ),
    ));
  }

  void _joinVideoCall() {
    if (_ringingIncomingCall) {
      _ringingIncomingCall = false;
      unawaited(_setCallRinging(false));
    }
    final call = FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .collection('calls')
        .doc('active');
    call.get().then((snapshot) {
      final audioOnly = snapshot.data()?['callType'] == 'audio';
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => VideoCallPage(
            chatId: widget.chatId,
            isCaller: false,
            audioOnly: audioOnly,
          ),
        ),
      );
    });
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
              Text(
                'Incoming ${_incomingCallType == 'audio' ? 'voice' : 'video'} call',
                style: const TextStyle(
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
                      label: Text(
                        tr('Decline'),
                        style: const TextStyle(color: Colors.red),
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
                      icon: Icon(_incomingCallType == 'audio'
                          ? Icons.call
                          : Icons.videocam),
                      label: Text(tr('Answer')),
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
