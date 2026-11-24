import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/app_constants.dart';
import '../i18n/tr.dart';

/// Opens one of the public pages on the Duhuze website (Firebase Hosting,
/// files in site/): privacy, terms, delete-account, child-safety.
Future<void> openLegalPage(String page) =>
    launchUrl(Uri.parse('${AppConstants.websiteUrl}/$page'),
        mode: LaunchMode.externalApplication);

/// "By creating an account you agree to the Terms and the Privacy policy."
class LegalConsentText extends StatelessWidget {
  const LegalConsentText({super.key});

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).textTheme.bodySmall;
    final link = base?.copyWith(
        color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600);
    return Text.rich(
      TextSpan(style: base, children: [
        TextSpan(text: tr('By creating an account you agree to the')),
        const TextSpan(text: ' '),
        TextSpan(
          text: tr('Terms of use'),
          style: link,
          recognizer: TapGestureRecognizer()..onTap = () => openLegalPage('terms'),
        ),
        TextSpan(text: ' ${tr('and the')} '),
        TextSpan(
          text: tr('Privacy policy'),
          style: link,
          recognizer: TapGestureRecognizer()..onTap = () => openLegalPage('privacy'),
        ),
        const TextSpan(text: '.'),
      ]),
      textAlign: TextAlign.center,
    );
  }
}
