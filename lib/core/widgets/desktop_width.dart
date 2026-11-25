import 'package:flutter/widgets.dart';

/// Keeps content at a readable width on big (desktop) screens and centres
/// it. On phones it does nothing visible.
class DesktopWidth extends StatelessWidget {
  const DesktopWidth({super.key, required this.child, this.maxWidth = 820});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
