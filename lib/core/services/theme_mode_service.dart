import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

enum AppThemeMode { light, dark }

class ThemeModeService {
  ThemeModeService._();

  static final ThemeModeService instance = ThemeModeService._();

  final ValueNotifier<AppThemeMode> mode =
      ValueNotifier<AppThemeMode>(AppThemeMode.dark);

  Future<void> loadFromUser() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    final data = doc.data() ?? {};
    final value = (data['themeMode'] ?? 'dark').toString();
    // 'cyber' was removed; anyone who had it gets dark mode.
    mode.value =
        value == 'light' ? AppThemeMode.light : AppThemeMode.dark;
  }

  Future<void> toggle() async {
    final current = mode.value;
    final newMode =
        current == AppThemeMode.light ? AppThemeMode.dark : AppThemeMode.light;
    mode.value = newMode;
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final modeValue = newMode == AppThemeMode.dark ? 'dark' : 'light';
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update({
        'themeMode': modeValue,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
  }
}
