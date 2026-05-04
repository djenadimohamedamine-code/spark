import 'package:flutter/material.dart';

/// MIMO SPARK - Thème Rouge & Noir Premium
/// Inspiré du style Racing Sport
class SparkTheme {
  // Couleurs Primaires
  static const Color primary = Color(0xFFE50000);       // Rouge Sport vif
  static const Color primaryDark = Color(0xFF9B0000);   // Rouge sombre (ombres)
  static const Color primaryLight = Color(0xFFFF4040);  // Rouge clair (hover)
  static const Color accent = Color(0xFFFF1A1A);        // Rouge accent (glow)
  
  // Fond
  static const Color background = Color(0xFF0A0A0A);    // Noir profond
  static const Color surface = Color(0xFF141414);       // Surface légèrement grisée
  static const Color surfaceCard = Color(0xFF1C1C1C);   // Carte foncée
  
  // Texte
  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Color(0xFFAAAAAA);

  // Getters pour les effets dynamiques (withOpacity nécessite une instance)
  static Color get primaryGlow => primary.withOpacity(0.3);
  static Color get accentSoft => accent.withOpacity(0.5);
  static Color get accentVerysoft => accent.withOpacity(0.1);

  static ThemeData get theme => ThemeData(
    brightness: Brightness.dark,
    primaryColor: primary,
    scaffoldBackgroundColor: background,
    colorScheme: const ColorScheme.dark(
      primary: primary,
      secondary: primaryLight,
      surface: surface,
      error: Color(0xFFCF6679),
    ),
    iconTheme: const IconThemeData(color: primary),
    appBarTheme: const AppBarTheme(
      backgroundColor: background,
      foregroundColor: Colors.white,
      iconTheme: IconThemeData(color: primary),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: primary,
      foregroundColor: Colors.white,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: Colors.white,
      ),
    ),
    tabBarTheme: const TabBarTheme(
      labelColor: primary,
      indicatorColor: primary,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: primary,
    ),
  );
}
