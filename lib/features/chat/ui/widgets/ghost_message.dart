part of '../chat_page.dart';

// Ghost-mode message bubble and its floating-letters animation.
class _GhostMessageContent extends StatefulWidget {
  const _GhostMessageContent({
    required this.encryptedText,
    required this.text,
    required this.isMe,
    required this.isDark,
    this.isEmojiOnly = false,
    this.onReveal,
    this.onHide,
  });

  final String encryptedText;
  final String text;
  final bool isMe;
  final bool isDark;
  final bool isEmojiOnly;
  final VoidCallback? onReveal;
  final VoidCallback? onHide;

  @override
  State<_GhostMessageContent> createState() => _GhostMessageContentState();
}

class _GhostMessageContentState extends State<_GhostMessageContent> {
  bool _revealed = false;
  bool _dissolving = false;

  Future<void> _handleTap() async {
    if (_dissolving) return;
    if (!_revealed) {
      setState(() {
        _revealed = true;
      });
      widget.onReveal?.call();
      return;
    }
    setState(() {
      _dissolving = true;
    });
    await Future.delayed(const Duration(milliseconds: 920));
    if (!mounted) return;
    setState(() {
      _revealed = false;
      _dissolving = false;
    });
    widget.onHide?.call();
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.isMe
        ? Colors.white
        : (widget.isDark ? const Color(0xFF61D1ED) : AppColors.primary);
    return Semantics(
      button: true,
      label: _revealed ? 'Hide encrypted message' : 'Reveal encrypted message',
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: _handleTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          constraints: const BoxConstraints(minWidth: 150),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: widget.isMe ? 0.12 : 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: accent.withValues(alpha: 0.28)),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: _revealed && !_dissolving
                    ? Text(
                        widget.text,
                        key: const ValueKey('revealed'),
                        style: TextStyle(
                          color: widget.isMe
                              ? Colors.white
                              : (widget.isDark ? Colors.white : Colors.black87),
                          fontWeight: FontWeight.w600,
                          fontSize: widget.isEmojiOnly
                              ? (widget.text.trim().runes.length <= 2
                                  ? 46
                                  : widget.text.trim().runes.length <= 5
                                      ? 36
                                      : 27)
                              : null,
                          height: widget.isEmojiOnly ? 1.2 : null,
                        ),
                      )
                    : ConstrainedBox(
                        key: const ValueKey('hidden'),
                        constraints: const BoxConstraints(maxWidth: 250),
                        child: Text(
                          widget.encryptedText,
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: accent,
                            fontSize: 12,
                            fontFamily: 'RobotoMono',
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0,
                          ),
                        ),
                      ),
              ),
              if (_dissolving)
                Positioned.fill(
                  child: IgnorePointer(
                    child: _FloatingGhostLetters(
                      text: widget.text,
                      color: accent,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FloatingGhostLetters extends StatefulWidget {
  const _FloatingGhostLetters({
    required this.text,
    required this.color,
  });

  final String text;
  final Color color;

  @override
  State<_FloatingGhostLetters> createState() => _FloatingGhostLettersState();
}

class _FloatingGhostLettersState extends State<_FloatingGhostLetters>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final List<_GhostLetterParticle> _particles;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 880),
    )..forward();
    final chars = widget.text.runes
        .map((rune) => String.fromCharCode(rune))
        .where((char) => char.trim().isNotEmpty)
        .take(34)
        .toList();
    final random = math.Random(widget.text.hashCode);
    _particles = List<_GhostLetterParticle>.generate(chars.length, (index) {
      return _GhostLetterParticle(
        char: chars[index],
        x: random.nextDouble(),
        rise: 16 + random.nextDouble() * 34,
        drift: (random.nextDouble() - 0.5) * 46,
        delay: random.nextDouble() * 0.22,
        scale: 0.74 + random.nextDouble() * 0.55,
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            return Stack(
              clipBehavior: Clip.none,
              children: _particles.map((particle) {
                final rawProgress =
                    ((_controller.value - particle.delay) / 0.78)
                        .clamp(0.0, 1.0);
                final eased = Curves.easeOutCubic.transform(rawProgress);
                return Positioned(
                  left: (constraints.maxWidth * particle.x) +
                      (particle.drift * eased),
                  top: (constraints.maxHeight * 0.48) - (particle.rise * eased),
                  child: Opacity(
                    opacity: (1 - eased).clamp(0.0, 1.0),
                    child: Transform.scale(
                      scale: particle.scale + (eased * 0.45),
                      child: Text(
                        particle.char,
                        style: TextStyle(
                          color: widget.color,
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            );
          },
        );
      },
    );
  }
}

class _GhostLetterParticle {
  const _GhostLetterParticle({
    required this.char,
    required this.x,
    required this.rise,
    required this.drift,
    required this.delay,
    required this.scale,
  });

  final String char;
  final double x;
  final double rise;
  final double drift;
  final double delay;
  final double scale;
}
