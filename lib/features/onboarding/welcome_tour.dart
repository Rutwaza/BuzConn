import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/i18n/tr.dart';
import '../../core/theme/colors.dart';

/// A short first-run tour (4 cards). Shown once per account: it saves
/// `tourSeenAt` on the user document.
class WelcomeTour {
  WelcomeTour._();

  static bool _checked = false;

  static Future<void> showIfNew(BuildContext context) async {
    if (_checked) return;
    _checked = true;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final ref = FirebaseFirestore.instance.collection('users').doc(uid);
    try {
      final data = (await ref.get()).data() ?? {};
      if (data['tourSeenAt'] != null) return;
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _TourDialog(),
      );
      await ref.set({'tourSeenAt': FieldValue.serverTimestamp()},
          SetOptions(merge: true));
    } catch (_) {
      // Never block the app because of the tour.
    }
  }
}

class _TourDialog extends StatefulWidget {
  const _TourDialog();

  @override
  State<_TourDialog> createState() => _TourDialogState();
}

class _TourDialogState extends State<_TourDialog> {
  final _pages = PageController();
  int _i = 0;

  List<(String, String, String)> get _steps => [
        ('👋', tr('Welcome to Duhuze'),
            tr('Africa connected: people, pages and shops in one place.')),
        ('✨', tr('Three ways to scroll'),
            tr('For You shows what is popular, Reels is videos only, and Following shows the people and pages you follow.')),
        ('🛍', tr('Shop on Duhuze'),
            tr('Pages can sell. Tap Shop or Buy on a post, pay with MoMo, and follow your order until it is delivered.')),
        ('📸', tr('Stories and chat'),
            tr('Share a 24-hour status with filters, text and stickers. React or reply to friends’ stories, and chat in private.')),
      ];

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final steps = _steps;
    final last = _i == steps.length - 1;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 14),
          child: Column(
            children: [
              Expanded(
                child: PageView(
                  controller: _pages,
                  onPageChanged: (i) => setState(() => _i = i),
                  children: [
                    for (final s in steps)
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(s.$1, style: const TextStyle(fontSize: 64)),
                          const SizedBox(height: 16),
                          Text(s.$2,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 22, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 10),
                          Text(s.$3,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 15, color: AppColors.grey, height: 1.4)),
                        ],
                      ),
                  ],
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var k = 0; k < steps.length; k++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.all(3),
                      width: k == _i ? 18 : 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: k == _i ? AppColors.primary : AppColors.lightGrey,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (!last)
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(tr('Skip')),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => last
                        ? Navigator.pop(context)
                        : _pages.nextPage(
                            duration: const Duration(milliseconds: 260),
                            curve: Curves.easeOutCubic),
                    child: Text(last ? tr('Let’s go') : tr('Next')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
