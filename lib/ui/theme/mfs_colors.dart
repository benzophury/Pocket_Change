import 'package:flutter/material.dart';

/// Design tokens and color palette for Pocket Change v1.1.0:
/// Matte Black with Crimson Red accent.
class MfsColors {
  MfsColors._();

  // --- Primary Brand Palette (Crimson Red) ---
  static const Color primary = Color(0xFFDC143C); // Classic Crimson Red
  static const Color primaryDark = Color(0xFF990F2D); // Deep Crimson
  static const Color primaryLight = Color(0x33DC143C); // Translucent Crimson Container

  // --- Accent Palette ---
  static const Color accent = Color(0xFFFF1E4B); // Electric Crimson Glow
  static const Color accentDark = Color(0xFF8B0021); // Dark Crimson Wine
  static const Color accentLight = Color(0x22DC143C); // Subtle Crimson Tint

  // --- Financial Flow Semantic Colors ---
  static const Color cashIn = Color(0xFF00E676); // Clean Mint Green (Inflow)
  static const Color cashInLight = Color(0x2200E676); // Mint Pill / Background
  static const Color cashInDark = Color(0xFF00B248); // Dark Mint

  static const Color cashOut = Color(0xFFDC143C); // Crimson Red (Outflow)
  static const Color cashOutLight = Color(0x28DC143C); // Light Crimson Pill
  static const Color cashOutDark = Color(0xFF990F2D); // Dark Crimson

  // --- Neutrals & Matte Black Surfaces ---
  static const Color background = Color(0xFF0D0D0D); // True Matte Black canvas
  static const Color surface = Color(0xFF171717); // Matte Charcoal Card Surface
  static const Color surfaceVariant = Color(0xFF222222); // Input & secondary container surface
  static const Color darkBackground = Color(0xFF0D0D0D); // Dark canvas
  static const Color darkSurface = Color(0xFF171717); // Dark card surface

  // --- Text Hierarchy ---
  static const Color textPrimary = Color(0xFFFFFFFF); // Pure white high contrast
  static const Color textSecondary = Color(0xFFA5A5A5); // Soft silver gray
  static const Color textMuted = Color(0xFF6E6E6E); // Hint & disabled text
  static const Color textOnPrimary = Color(0xFFFFFFFF); // Crisp white on crimson

  // --- Borders & Dividers ---
  static const Color border = Color(0xFF2C2C2C); // Matte dark border
  static const Color divider = Color(0xFF202020); // Subtle divider

  // --- Signature Gradients ---
  static const LinearGradient primaryCardGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF241014), Color(0xFF151515)],
  );

  static const LinearGradient crimsonGlowGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [primary, primaryDark],
  );

  static const LinearGradient nagadCardGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF2A1015), Color(0xFF181818)],
  );

  static const LinearGradient slateGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF1C1C1C), Color(0xFF121212)],
  );

  // --- Box Shadows & Crimson Glows ---
  static const List<BoxShadow> cardShadow = [
    BoxShadow(
      color: Color(0x66000000),
      blurRadius: 10,
      offset: Offset(0, 4),
    ),
  ];

  static const List<BoxShadow> cardElevatedShadow = [
    BoxShadow(
      color: Color(0x40DC143C),
      blurRadius: 16,
      offset: Offset(0, 6),
    ),
  ];

  static const List<BoxShadow> pillShadow = [
    BoxShadow(
      color: Color(0x40000000),
      blurRadius: 8,
      offset: Offset(0, 3),
    ),
  ];

  // --- Material 3 Theme Generators ---
  static ThemeData buildLightTheme() {
    return _buildTheme(Brightness.dark);
  }

  static ThemeData buildDarkTheme() {
    return _buildTheme(Brightness.dark);
  }

  static ThemeData _buildTheme(Brightness brightness) {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: primary,
        secondary: accent,
        surface: surface,
        error: cashOut,
        onPrimary: textOnPrimary,
        onSurface: textPrimary,
      ),
      scaffoldBackgroundColor: background,
      appBarTheme: const AppBarTheme(
        backgroundColor: surface,
        foregroundColor: textPrimary,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16.0),
          side: const BorderSide(color: border, width: 1.0),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18.0),
          side: const BorderSide(color: border, width: 1.0),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceVariant,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14.0),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14.0),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14.0),
          borderSide: const BorderSide(color: primary, width: 1.8),
        ),
        hintStyle: const TextStyle(color: textMuted),
        labelStyle: const TextStyle(color: textSecondary),
      ),
    );
  }
}

/// Type alias for modern naming
typedef AppColors = MfsColors;
