import 'dart:async';

import 'package:flutter/material.dart';

import '../routes/router.dart';

enum ToastKind { success, error, info }

/// A small popup that flashes over the app for a few seconds: top-right on
/// desktop, top-centre on phones. Replaces the plain bar at the bottom.
///
///   showToast(context, 'Saved');                 // kind is guessed from the words
///   showToast(context, 'Upload failed', kind: ToastKind.error);
void showToast(BuildContext? context, String message, {ToastKind? kind}) {
  final text = message.trim();
  if (text.isEmpty) return;
  final k = kind ?? _guess(text);

  OverlayState? overlay;
  if (context != null) overlay = Overlay.maybeOf(context, rootOverlay: true);
  overlay ??= AppRouter.router.routerDelegate.navigatorKey.currentState?.overlay;
  if (overlay == null) {
    // No screen to draw on: fall back to the normal bar.
    final m = AppRouter.scaffoldMessengerKey.currentState;
    m?.hideCurrentSnackBar();
    m?.showSnackBar(SnackBar(content: Text(text)));
    return;
  }
  _ToastHost.show(overlay, text, k);
}

ToastKind _guess(String t) {
  final s = t.toLowerCase();
  const bad = [
    'fail', 'could not', "couldn't", 'cannot', "can't", 'error', 'denied',
    'refused', 'not allowed', 'unable', 'wrong', 'invalid', 'too large',
    'not done', 'try again', 'not found', 'unexpected', 'missing',
  ];
  for (final w in bad) {
    if (s.contains(w)) return ToastKind.error;
  }
  const good = [
    'saved', 'sent', 'done', 'added', 'removed', 'updated', 'copied', 'posted',
    'deleted', 'success', 'thank', 'welcome', 'created', 'paid', 'verified',
    'published', 'followed', 'unfollowed', 'cleared', 'restored',
  ];
  for (final w in good) {
    if (s.contains(w)) return ToastKind.success;
  }
  return ToastKind.info;
}

class _ToastHost {
  static OverlayEntry? _entry;
  static Timer? _timer;
  static GlobalKey<_ToastCardState>? _key;

  static void show(OverlayState overlay, String text, ToastKind kind) {
    _timer?.cancel();
    _entry?.remove();
    final key = GlobalKey<_ToastCardState>();
    _key = key;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _ToastCard(
        key: key,
        text: text,
        kind: kind,
        onClosed: () {
          if (_entry == entry) {
            entry.remove();
            _entry = null;
          }
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
    _timer = Timer(
      Duration(milliseconds: kind == ToastKind.error ? 4800 : 2800),
      () => _key?.currentState?.close(),
    );
  }
}

class _ToastCard extends StatefulWidget {
  const _ToastCard({
    super.key,
    required this.text,
    required this.kind,
    required this.onClosed,
  });
  final String text;
  final ToastKind kind;
  final VoidCallback onClosed;

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    reverseDuration: const Duration(milliseconds: 200),
  )..forward();

  Future<void> close() async {
    if (!mounted) return;
    await _c.reverse();
    widget.onClosed();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final (accent, icon) = switch (widget.kind) {
      ToastKind.success => (const Color(0xFF22C55E), Icons.check_circle_rounded),
      ToastKind.error => (const Color(0xFFEF4444), Icons.error_rounded),
      ToastKind.info => (const Color(0xFF3B82F6), Icons.info_rounded),
    };
    final curve = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    return Positioned(
      top: MediaQuery.paddingOf(context).top + (wide ? 18 : 12),
      left: wide ? null : 12,
      right: wide ? 18 : 12,
      child: FadeTransition(
        opacity: curve,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: wide ? const Offset(0.25, 0) : const Offset(0, -0.4),
            end: Offset.zero,
          ).animate(curve),
          child: Align(
            alignment: Alignment.topRight,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Material(
                color: Colors.transparent,
                child: GestureDetector(
                  onTap: close,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
                    decoration: BoxDecoration(
                      color: const Color(0xF2161B26),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: accent.withValues(alpha: 0.55)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.35),
                          blurRadius: 24,
                          offset: const Offset(0, 10),
                        ),
                        BoxShadow(
                          color: accent.withValues(alpha: 0.18),
                          blurRadius: 18,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(icon, color: accent, size: 22),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            widget.text,
                            maxLines: 5,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              height: 1.3,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
