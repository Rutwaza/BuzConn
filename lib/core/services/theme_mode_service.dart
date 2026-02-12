import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

enum AppThemeMode { light, dark, cyber }

class ThemeModeService {
  ThemeModeService._();

  static final ThemeModeService instance = ThemeModeService._();

  final ValueNotifier<AppThemeMode> mode =
      ValueNotifier<AppThemeMode>(AppThemeMode.light);

  Future<void> loadFromUser() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    final data = doc.data() ?? {};
    final value = (data['themeMode'] ?? 'light').toString();
    if (value == 'dark') {
      mode.value = AppThemeMode.dark;
    } else if (value == 'cyber') {
      mode.value = AppThemeMode.cyber;
    } else {
      mode.value = AppThemeMode.light;
    }
  }

  Future<void> toggle() async {
    final current = mode.value;
    final newMode = current == AppThemeMode.light
        ? AppThemeMode.dark
        : current == AppThemeMode.dark
            ? AppThemeMode.cyber
            : AppThemeMode.light;
    mode.value = newMode;
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final modeValue = newMode == AppThemeMode.dark
          ? 'dark'
          : newMode == AppThemeMode.cyber
              ? 'cyber'
              : 'light';
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update({
        'themeMode': modeValue,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
  }
}
