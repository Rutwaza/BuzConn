import 'package:flutter/material.dart';

import 'app_toast.dart';

/// Kept for the sign-in screens: now shows the same popup as the rest of the app.
void showSpotlightToast(
  BuildContext context,
  String message, {
  required bool success,
  Duration duration = const Duration(milliseconds: 2100),
  EdgeInsets margin = const EdgeInsets.fromLTRB(12, 0, 12, 96),
}) {
  showToast(context, message,
      kind: success ? ToastKind.success : ToastKind.error);
}
