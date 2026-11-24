import 'package:flutter/material.dart';
import 'package:businessfinder/core/i18n/tr.dart';

Future<void> showEmailVerificationNotice(
  BuildContext context, {
  required String email,
  required bool emailSent,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      icon: Icon(
        emailSent ? Icons.mark_email_unread_outlined : Icons.email_outlined,
        color: Theme.of(dialogContext).colorScheme.primary,
        size: 34,
      ),
      title: Text(tr('Verify your email')),
      content: Text(
        emailSent
            ? 'We sent a verification link to $email. Open the email and follow its link before signing in. Check your spam folder too.'
            : 'We could not send the verification email to $email. Return to sign in; we will try sending it again after you enter your password.',
        textAlign: TextAlign.center,
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(tr('Continue to sign in')),
        ),
      ],
    ),
  );
}
