import 'package:flutter/material.dart';

class AppColors {
  // Duhuze brand: calm "Kivu blue" (see the product vision doc).
  static const Color primary = Color(0xFF3A6EA5); // Kivu blue
  static const Color primaryDark = Color(0xFF0E1A2B); // night navy
  static const Color primaryLight = Color(0xFF9CC3EE); // sky
  static const Color mist = Color(0xFFEEF3F9); // light surfaces
  static const Color gold = Color(0xFFE8B931); // small accents only

  // Secondary: teal for verified badges and business pages.
  static const Color secondary = Color(0xFF14B8A6);
  static const Color secondaryDark = Color(0xFF0F8F82);
  static const Color secondaryLight = Color(0xFF5EEAD4);
  
  // Neutral Colors
  static const Color black = Color(0xFF1A1A1A);
  static const Color darkGrey = Color(0xFF424242);
  static const Color grey = Color(0xFF757575);
  static const Color lightGrey = Color(0xFFE0E0E0);
  static const Color white = Color(0xFFFFFFFF);
  static const Color background = Color(0xFFF8F9FA);
  
  // Semantic Colors
  static const Color success = Color(0xFF4CAF50);
  static const Color warning = Color(0xFFFF9800);
  static const Color error = Color(0xFFE5484D);
  static const Color info = Color(0xFF2196F3);
  
  // Gradient
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [primary, primaryLight],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}