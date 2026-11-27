part of '../chat_page.dart';

// Small building blocks of the chat screen: buttons, status line,
// voice-note player, typing dots.
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

  static String statusText({
    required String? otherUserId,
    required bool isTyping,
    required String chatType,
  }) {
    if (isTyping) return 'typing...';
    if (otherUserId == null || otherUserId.isEmpty) {
      return chatType == 'direct' ? 'Conversation' : 'Creator chat';
    }
    return chatType == 'direct'
        ? 'Shared conversation'
        : 'Business conversation';
  }

  @override
  Widget build(BuildContext context) {
    if (isTyping) {
      return Text(
        tr('typing...'),
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
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

    // Real online status from the Realtime Database (PresenceService).
    return StreamBuilder<({bool isOnline, DateTime? lastSeen})>(
      stream: PresenceService.instance.watchStatus(otherUserId!),
      builder: (context, snapshot) {
        final isOnline = snapshot.data?.isOnline ?? false;
        final lastSeen = snapshot.data?.lastSeen;
        final text = isOnline
            ? 'Active now'
            : lastSeen == null
                ? (chatType == 'direct' ? 'Offline' : 'Creator chat')
                : _formatActivity(lastSeen);
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
  const _AudioMessageTile({
    required this.url,
    required this.chatId,
    required this.isMe,
  });

  final String url;
  final String chatId;
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
    6,
    10,
    14,
    8,
    16,
    12,
    6,
    18,
    9,
    14,
    8,
    12,
    6,
    10,
    7,
    15
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
    final url = await R2StorageService.instance.downloadPrivateMediaUrl(
      mediaRef: widget.url,
      chatId: widget.chatId,
    );
    await _player.play(UrlSource(url));
    if (mounted) {
      setState(() => _isPlaying = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final total =
        _duration.inMilliseconds > 0 ? _duration : const Duration(seconds: 1);
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

/// A picture in a chat bubble: rounded, no heavy box around it, shows a soft
/// placeholder while loading and a tap-to-retry card when it cannot load
/// (instead of a red error box).
class _ChatPhoto extends StatefulWidget {
  const _ChatPhoto({
    required this.resolve,
    this.onTap,
    this.width = 260,
    this.height,
    this.radius = 18,
    this.square = false,
  });

  final Future<String> Function() resolve;
  final VoidCallback? onTap;
  final double width;
  final double? height;
  final double radius;
  final bool square;

  @override
  State<_ChatPhoto> createState() => _ChatPhotoState();
}

class _ChatPhotoState extends State<_ChatPhoto> {
  late Future<String> _url = widget.resolve();
  int _attempt = 0;

  void _retry() => setState(() {
        _attempt++;
        _url = widget.resolve();
      });

  Widget _box(Widget child) => SizedBox(
        width: widget.square ? null : widget.width,
        height: widget.height ?? (widget.square ? null : 160),
        child: child,
      );

  Widget _soft({required Widget child, VoidCallback? onTap}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return _box(
      Material(
        color: isDark ? Colors.white10 : Colors.black12,
        borderRadius: BorderRadius.circular(widget.radius),
        child: InkWell(
          borderRadius: BorderRadius.circular(widget.radius),
          onTap: onTap,
          child: Center(child: child),
        ),
      ),
    );
  }

  Widget _broken() => _soft(
        onTap: _retry,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image_not_supported_outlined, size: 26),
            if (!widget.square) ...[
              const SizedBox(height: 6),
              Text(tr('Could not load · tap to retry'),
                  style: const TextStyle(fontSize: 11)),
            ],
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _url,
      builder: (context, snap) {
        if (snap.hasError) return _broken();
        final url = snap.data;
        if (url == null) {
          return _soft(
            child: const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        return GestureDetector(
          onTap: widget.onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(widget.radius),
            child: _box(
              Image.network(
                url,
                key: ValueKey(_attempt),
                fit: BoxFit.cover,
                width: widget.square ? null : widget.width,
                height: widget.height ?? (widget.square ? null : 160),
                errorBuilder: (_, __, ___) => _broken(),
                loadingBuilder: (c, child, progress) => progress == null
                    ? child
                    : _soft(
                        child: const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A video in a chat bubble: thumbnail (when the phone can make one) with a
/// play button.
class _ChatVideoThumb extends StatefulWidget {
  const _ChatVideoThumb({
    required this.resolve,
    required this.thumbnail,
    this.onTap,
    this.width = 260,
    this.height = 160,
  });

  final Future<String> Function() resolve;
  final Future<Uint8List?> Function(String url) thumbnail;
  final VoidCallback? onTap;
  final double width;
  final double height;

  @override
  State<_ChatVideoThumb> createState() => _ChatVideoThumbState();
}

class _ChatVideoThumbState extends State<_ChatVideoThumb> {
  late final Future<Uint8List?> _thumb =
      widget.resolve().then(widget.thumbnail).catchError((_) => null);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: widget.onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: FutureBuilder<Uint8List?>(
            future: _thumb,
            builder: (context, snap) {
              final bytes = snap.data;
              return Stack(
                fit: StackFit.expand,
                children: [
                  if (bytes != null)
                    Image.memory(bytes, fit: BoxFit.cover)
                  else
                    ColoredBox(color: isDark ? Colors.white10 : Colors.black12),
                  Center(
                    child: Container(
                      width: 46,
                      height: 46,
                      decoration: const BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.play_arrow_rounded,
                          color: Colors.white, size: 30),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Small clear "Download" button that stays readable on any bubble colour.
class _DownloadPill extends StatelessWidget {
  const _DownloadPill({required this.isMe, required this.onTap});
  final bool isMe;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isMe
        ? Colors.white.withValues(alpha: 0.22)
        : (isDark ? Colors.white12 : AppColors.primary.withValues(alpha: 0.12));
    final fg = isMe ? Colors.white : (isDark ? Colors.white : AppColors.primary);
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.download_rounded, size: 16, color: fg),
              const SizedBox(width: 6),
              Text(
                tr('Download'),
                style: TextStyle(
                    color: fg, fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
