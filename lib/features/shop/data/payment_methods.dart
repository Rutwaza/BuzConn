import 'dart:io' show Platform;

import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_constants.dart';

/// Ways to pay. Today: MoMo Pay through USSD. When Duhuze signs with a gateway,
/// add a new class here (see functions/payments/gateway-template.js for the
/// server side) and return it from [PaymentMethods.current].
abstract class PaymentMethod {
  String get label;

  /// True when the server learns by itself that the buyer paid (a gateway).
  /// False for USSD: the buyer says "I paid" and the shop confirms.
  bool get automatic;

  /// Starts the payment on this phone. Returns false if it could not start.
  Future<bool> start({required String merchantCode, required int amount});
}

class MomoUssdPayment implements PaymentMethod {
  const MomoUssdPayment();

  @override
  String get label => 'MTN MoMo Pay';

  @override
  bool get automatic => false;

  /// "*182*8*1*123456*5000#" with the # written as %23 so the dialer keeps it.
  static String ussdFor(String merchantCode, int amount) =>
      AppConstants.momoPayUssd
          .replaceAll('{code}', merchantCode)
          .replaceAll('{amount}', '$amount');

  @override
  Future<bool> start(
      {required String merchantCode, required int amount}) async {
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    final code = ussdFor(merchantCode, amount).replaceAll('#', '%23');
    // Opens the phone dialer with the code typed in. The buyer presses the
    // green call button, then MTN shows the PIN pop-up.
    return launchUrl(Uri.parse('tel:$code'));
  }
}

class PaymentMethods {
  static PaymentMethod get current => const MomoUssdPayment();
}
