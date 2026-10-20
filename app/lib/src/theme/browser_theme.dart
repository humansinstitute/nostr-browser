import 'package:flutter/material.dart';

import 'browser_palette.dart';

/// Shared palette for app-owned surfaces. Embedded pages keep their own styles.
abstract final class BrowserTheme {
  static const frame = Color(BrowserPalette.frame);
  static const activeTab = Color(BrowserPalette.activeTab);
  static const lavender = Color(BrowserPalette.lavender);
  static const purple = Color(BrowserPalette.purple);
  static const paper = Color(BrowserPalette.paper);
  static const ink = Color(BrowserPalette.ink);
  static const orange = Color(BrowserPalette.orange);
  static const outline = Color(BrowserPalette.outline);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(seedColor: purple).copyWith(
      primary: purple,
      onPrimary: Colors.white,
      primaryContainer: const Color(0xFFEBDDF8),
      onPrimaryContainer: ink,
      secondary: const Color(0xFF87400C),
      onSecondary: Colors.white,
      surface: paper,
      onSurface: ink,
      onSurfaceVariant: const Color(0xFF62516E),
      outline: outline,
      outlineVariant: const Color(0xFFD6C7E0),
      error: const Color(0xFFAD243A),
      onError: Colors.white,
    );
    const shape = BeveledRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(8)),
      side: BorderSide(color: Color(0xFFD6C7E0)),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: paper,
      focusColor: purple.withValues(alpha: .18),
      hoverColor: purple.withValues(alpha: .08),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: paper,
        border: OutlineInputBorder(),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: purple, width: 2),
        ),
      ),
      cardTheme: const CardThemeData(
        color: paper,
        surfaceTintColor: Colors.transparent,
        shape: shape,
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: paper,
        surfaceTintColor: Colors.transparent,
        shape: shape,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: paper,
        surfaceTintColor: Colors.transparent,
        shape: shape,
        textStyle:
            const TextStyle(color: ink, fontSize: 14, fontFamily: 'Roboto'),
        labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
              fontFamily: 'Roboto',
              fontSize: 14,
              color: states.contains(WidgetState.disabled)
                  ? const Color(0xFF796C81)
                  : ink,
            )),
        iconColor: ink,
      ),
      listTileTheme: const ListTileThemeData(
        textColor: ink,
        iconColor: ink,
        selectedColor: purple,
      ),
      navigationDrawerTheme: const NavigationDrawerThemeData(
        backgroundColor: paper,
        surfaceTintColor: Colors.transparent,
        indicatorColor: Color(0xFFEBDDF8),
      ),
      tooltipTheme: const TooltipThemeData(
        decoration: BoxDecoration(
            color: frame, borderRadius: BorderRadius.all(Radius.circular(4))),
        textStyle: TextStyle(color: lavender, fontSize: 12),
      ),
    );
  }

  /// Purple frame, with light address field and menus kept on reading surfaces.
  static ThemeData chrome(ThemeData base) => base.copyWith(
        colorScheme: base.colorScheme.copyWith(
          surface: frame,
          surfaceContainerHighest: frame,
          onSurface: lavender,
          onSurfaceVariant: const Color(0xFFD0BDDF),
          outlineVariant: const Color(0xFF674C7D),
        ),
        iconTheme: const IconThemeData(color: lavender),
        iconButtonTheme: IconButtonThemeData(
            style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.disabled)
                  ? const Color(0xFFAA95BA)
                  : lavender),
          overlayColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.focused)
                  ? const Color(0xFF79538F)
                  : const Color(0x335B4073)),
        )),
        inputDecorationTheme: base.inputDecorationTheme.copyWith(
          prefixIconColor: purple,
          hintStyle: const TextStyle(color: Color(0xFF62516E)),
          focusedBorder: const OutlineInputBorder(
            borderSide: BorderSide(color: Color(0xFF9A480D), width: 2),
          ),
        ),
        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: purple,
          selectionColor: Color(0xFFD9BFEF),
          selectionHandleColor: purple,
        ),
      );
}
