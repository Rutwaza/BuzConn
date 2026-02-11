import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class ThemeModeService {
  ThemeModeService._();

  static final ThemeModeService instance = ThemeModeService._();

  final ValueNotifier<ThemeMode> mode = ValueNotifier(ThemeMode.light);

  Future<void> loadFromUser() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    final data = doc.data() ?? {};
    final value = (data['themeMode'] ?? 'light').toString();
    mode.value = value == 'dark' ? ThemeMode.dark : ThemeMode.light;
  }

  Future<void> toggle() async {
    final newMode =
        mode.value == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    mode.value = newMode;
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update({
        'themeMode': newMode == ThemeMode.dark ? 'dark' : 'light',
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
  }
}
