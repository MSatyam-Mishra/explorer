import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // Define our custom color palette
  static const Color _darkPrimary = Color(
    0xFFE0E0E0,
  ); // Very light grey for subtle accents
  static const Color _darkBackground = Color(0xFF121212); // A deep, rich black
  static const Color _darkSurface = Color(
    0xFF1E1E1E,
  ); // A slightly lighter black for cards/surfaces
  static const Color _darkOnSurface = Color(
    0xFFE0E0E0,
  ); // An off-white for text

  static final ThemeData lightTheme = ThemeData(
    // We'll build this out later
    useMaterial3: true,
    brightness: Brightness.light,
  );

  static final ThemeData darkTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,

    // 1. Color Scheme
    scaffoldBackgroundColor: _darkBackground,
    colorScheme: const ColorScheme.dark(
      primary: _darkPrimary,
      surface: _darkSurface,
      onPrimary: Colors.black,
      onSurface: _darkOnSurface,
    ),
    // 2. Text Theme (using Google Fonts)
    textTheme: GoogleFonts.poppinsTextTheme(
      ThemeData.dark().textTheme.apply(bodyColor: _darkOnSurface),
    ),

    // 3. AppBar Theme
    appBarTheme: const AppBarTheme(
      backgroundColor:
          _darkSurface, // Appbar will be slightly lighter than the background
      elevation: 0, // No shadow for a flat, modern look
      foregroundColor: _darkOnSurface,
    ),

    // 4. Button Themes
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.all(
          _darkSurface.withOpacity(0.8),
        ), // Slightly transparent dark surface
        foregroundColor: WidgetStateProperty.all(_darkOnSurface),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        padding: WidgetStateProperty.all(
          const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
        ),
      ),
    ),
  );
}
