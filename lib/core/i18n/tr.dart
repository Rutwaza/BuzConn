import 'dart:ui' show PlatformDispatcher;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';

import 'rw_strings.dart';

/// App languages. English is the source text; Kinyarwanda comes from
/// [rwStrings]. To translate a new string, wrap it: `Text(tr('Hello'))`, then
/// add `'Hello': 'Muraho'` to rw_strings.dart. A missing translation simply
/// shows the English text, so nothing breaks.
///
/// Flutter's own built-in texts (date picker, copy/paste menu) stay in
/// English: Flutter has no Kinyarwanda for them.
enum AppLanguage {
  en('English'),
  rw('Ikinyarwanda');

  const AppLanguage(this.label);
  final String label;
}

class LanguageService {
  LanguageService._();
  static final LanguageService instance = LanguageService._();

  /// Starts with the phone's language (Kinyarwanda phones get Kinyarwanda).
  final ValueNotifier<AppLanguage> language = ValueNotifier(
    PlatformDispatcher.instance.locale.languageCode == 'rw'
        ? AppLanguage.rw
        : AppLanguage.en,
  );

  AppLanguage get current => language.value;

  /// Reads the saved choice from the user's profile (like the theme).
  Future<void> loadFromUser() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
    final saved = doc.data()?['language'];
    if (saved == 'rw' || saved == 'en') _apply(AppLanguage.values.byName(saved));
  }

  Future<void> set(AppLanguage lang) async {
    _apply(lang);
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update({
        'language': lang.name,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
  }

  void _apply(AppLanguage lang) {
    if (language.value == lang) return;
    language.value = lang;
    // Redraw every screen so all tr() texts change at once.
    WidgetsBinding.instance.reassembleApplication();
  }
}

/// Translate an English UI text into the chosen language.
String tr(String english) {
  if (LanguageService.instance.current == AppLanguage.rw) {
    return rwStrings[english] ?? english;
  }
  return english;
}
