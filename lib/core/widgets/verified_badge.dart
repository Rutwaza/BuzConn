import 'package:flutter/material.dart';

import '../i18n/tr.dart';

/// The blue ✓ next to the name of a verified (real, checked) business.
class VerifiedBadge extends StatelessWidget {
  const VerifiedBadge({super.key, this.size = 16});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tr('Verified business'),
      child: Icon(Icons.verified_rounded,
          size: size, color: const Color(0xFF1D9BF0)),
    );
  }
}
