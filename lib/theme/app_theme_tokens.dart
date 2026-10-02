import 'package:flutter/material.dart';

class AppThemeTokens {
  AppThemeTokens._();

  static const Color lightSeedColor = Color(0xFF4F46E5);
  static const Color lightPrimary = Color(0xFF4F46E5);
  static const Color lightOnPrimary = Colors.white;
  static const Color darkSeedColor = Color(0xFF818CF8);
  static const Color darkPrimary = Color(0xFF818CF8);
  static const Color darkOnPrimary = Color(0xFF1E1B4B);

  static ColorScheme applyLightPrimary(ColorScheme scheme) {
    return scheme.copyWith(primary: lightPrimary, onPrimary: lightOnPrimary);
  }

  static ColorScheme applyDarkPrimary(ColorScheme scheme) {
    return scheme.copyWith(primary: darkPrimary, onPrimary: darkOnPrimary);
  }
}
