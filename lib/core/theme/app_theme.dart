import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // Our app's signature gradient. This will be used for both themes.
  static const Gradient primaryGradient = LinearGradient(
    colors: [Color(0xFF64B5F6), Color(0xFF2196F3)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // --- DARK THEME ---
  static final ThemeData darkTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: Colors.black, // PURE BLACK background
    
    // A solid blue as a fallback primary color
    colorScheme: const ColorScheme.dark(
      primary: Color(0xFF2196F3),
      background: Colors.black,
      surface: Color(0xFF1A1A1A), // A very dark grey for subtle surfaces
      onSurface: Colors.white,
    ),

    textTheme: GoogleFonts.poppinsTextTheme(
      ThemeData.dark().textTheme.apply(
        bodyColor: Colors.white,
        displayColor: Colors.white,
      ),
    ),

    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.black,
      elevation: 0,
    ),

    dividerTheme: DividerThemeData(
      color: Colors.grey.shade800,
      thickness: 0.5,
    ),
  );

  // --- LIGHT THEME ---
  static final ThemeData lightTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: Colors.white, // PURE WHITE background

    colorScheme: const ColorScheme.light(
      primary: Color(0xFF2196F3),
      background: Colors.white,
      surface: Color(0xFFF5F5F5), // A very light grey for subtle surfaces
      onSurface: Colors.black,
    ),
    
    textTheme: GoogleFonts.poppinsTextTheme(
      ThemeData.light().textTheme,
    ),

    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.white,
      elevation: 0,
      iconTheme: IconThemeData(color: Colors.black),
      titleTextStyle: TextStyle(color: Colors.black, fontSize: 20, fontWeight: FontWeight.w500),
    ),

    dividerTheme: DividerThemeData(
      color: Colors.grey.shade200,
      thickness: 1,
    ),
  );
}