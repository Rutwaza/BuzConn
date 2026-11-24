import 'package:firebase_auth/firebase_auth.dart';
import 'package:businessfinder/core/i18n/tr.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:country_code_picker/country_code_picker.dart';

import '../../../core/theme/colors.dart';

Future<UserCredential?> showPhoneSignInSheet(BuildContext context) {
  return showModalBottomSheet<UserCredential>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _PhoneSignInSheet(),
  );
}

class _PhoneSignInSheet extends StatefulWidget {
  const _PhoneSignInSheet();

  @override
  State<_PhoneSignInSheet> createState() => _PhoneSignInSheetState();
}

class _PhoneSignInSheetState extends State<_PhoneSignInSheet> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  String _dialCode = '+250';
  String _fullPhone = '';
  String? _verificationId;
  int? _resendToken;
  String? _error;
  bool _codeSent = false;
  bool _isSending = false;
  bool _isVerifying = false;
  bool _isCompletingSignIn = false;
  bool _finished = false;

  bool get _isBusy => _isSending || _isVerifying;

  @override
  void dispose() {
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _sendCode({bool resend = false}) async {
    final enteredNumber = _phoneController.text.trim();
    final digits = enteredNumber.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 6) {
      setState(() => _error = 'Enter a valid phone number.');
      return;
    }

    final nationalNumber = digits.startsWith('0') ? digits.substring(1) : digits;
    final dialDigits = _dialCode.replaceAll(RegExp(r'\D'), '');
    final alreadyInternational = enteredNumber.startsWith('+') ||
        (digits.startsWith(dialDigits) &&
            digits.length > dialDigits.length + 6);
    _fullPhone = alreadyInternational ? '+$digits' : '$_dialCode$nationalNumber';

    setState(() {
      _isSending = true;
      _error = null;
    });

    try {
      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: _fullPhone,
        forceResendingToken: resend ? _resendToken : null,
        verificationCompleted: _completeSignIn,
        verificationFailed: (exception) {
          if (!mounted) return;
          setState(() {
            _isSending = false;
            _error = exception.message ?? 'Phone verification failed.';
          });
        },
        codeSent: (verificationId, resendToken) {
          if (!mounted) return;
          setState(() {
            _verificationId = verificationId;
            _resendToken = resendToken;
            _codeSent = true;
            _isSending = false;
            _error = null;
          });
        },
        codeAutoRetrievalTimeout: (verificationId) {
          _verificationId = verificationId;
        },
      );
    } on FirebaseAuthException catch (exception) {
      if (!mounted) return;
      setState(() {
        _isSending = false;
        _error = exception.message ?? 'Could not send the verification code.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isSending = false;
        _error = 'Could not send the verification code. Please try again.';
      });
    }
  }

  Future<void> _verifyCode() async {
    final verificationId = _verificationId;
    final code = _codeController.text.trim();
    if (verificationId == null || code.length < 6) {
      setState(() => _error = 'Enter the 6-digit code we sent you.');
      return;
    }

    setState(() {
      _isVerifying = true;
      _error = null;
    });

    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId,
        smsCode: code,
      );
      await _completeSignIn(credential);
    } on FirebaseAuthException catch (exception) {
      if (!mounted) return;
      setState(() {
        _isVerifying = false;
        _error = exception.message ?? 'That code is incorrect or expired.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isVerifying = false;
        _error = 'Could not verify the code. Please try again.';
      });
    }
  }

  Future<void> _completeSignIn(PhoneAuthCredential credential) async {
    if (_finished || _isCompletingSignIn || !mounted) return;
    _isCompletingSignIn = true;
    setState(() {
      _isVerifying = true;
      _isSending = false;
      _error = null;
    });

    try {
      final userCredential =
          await FirebaseAuth.instance.signInWithCredential(credential);
      if (!mounted || _finished) return;
      _finished = true;
      Navigator.of(context).pop(userCredential);
    } on FirebaseAuthException catch (exception) {
      _isCompletingSignIn = false;
      if (!mounted) return;
      setState(() {
        _isVerifying = false;
        _error = exception.message ?? 'Phone sign-in failed.';
      });
    } catch (error) {
      _isCompletingSignIn = false;
      if (!mounted) return;
      setState(() {
        _isVerifying = false;
        _error = 'Phone sign-in failed: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return SafeArea(
      top: false,
      child: Container(
        padding: EdgeInsets.fromLTRB(24, 12, 24, bottomInset + 24),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          border: Border.all(color: colors.outlineVariant.withOpacity(0.55)),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.onSurface.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: tr('Close'),
                  onPressed: _isBusy ? null : () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.phone_iphone_rounded,
                  color: AppColors.primary,
                  size: 28,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _codeSent ? 'Verify your phone' : 'Continue with phone',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _codeSent
                    ? 'Enter the 6-digit code sent to\n$_fullPhone'
                    : 'We’ll text you a one-time code to confirm your number.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 24),
              if (!_codeSent)
                TextField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: tr('Phone number'),
                    hintText: '78 123 4567',
                    prefixIcon: CountryCodePicker(
                      initialSelection: 'RW',
                      favorite: const ['RW', 'KE', 'UG', 'TZ'],
                      showFlag: true,
                      showCountryOnly: false,
                      showOnlyCountryWhenClosed: false,
                      onChanged: (country) {
                        _dialCode = country.dialCode ?? '+250';
                      },
                    ),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 112,
                      maxWidth: 132,
                      minHeight: 56,
                      maxHeight: 56,
                    ),
                  ),
                )
              else ...[
                TextField(
                  controller: _codeController,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                  decoration: InputDecoration(
                    labelText: tr('Verification code'),
                    hintText: '123456',
                    prefixIcon: const Icon(Icons.lock_outline_rounded),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(
                      onPressed: _isBusy
                          ? null
                          : () => setState(() {
                                _codeSent = false;
                                _verificationId = null;
                                _error = null;
                              }),
                      child: Text(tr('Change number')),
                    ),
                    TextButton(
                      onPressed: _isBusy ? null : () => _sendCode(resend: true),
                      child: Text(tr('Resend code')),
                    ),
                  ],
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.error,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: _isBusy ? null : (_codeSent ? _verifyCode : _sendCode),
                  child: _isBusy
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_codeSent ? 'Verify and continue' : 'Send code'),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                tr('Standard message and data rates may apply.'),
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
