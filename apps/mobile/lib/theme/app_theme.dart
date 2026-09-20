import 'package:flutter/material.dart';

import 'tokens.dart';

/// The single theme of the app.
///
/// Dark-first and high-contrast (FR-MG05). Typography follows the reference's
/// geometric/humanist sans; the platform default is used instead of shipping a
/// font asset, and every *size* still comes from [AppTextSizes] so the largest
/// system font scale is handled by layout rather than by truncation (FR-MG06).
ThemeData buildAppTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: AppColors.accent,
    onPrimary: AppColors.onAccent,
    secondary: AppColors.orbTop,
    onSecondary: AppColors.onUserBubble,
    error: AppColors.danger,
    onError: AppColors.onAccent,
    surface: AppColors.surface,
    onSurface: AppColors.textPrimary,
  );

  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
  final textTheme = base.textTheme.copyWith(
    headlineMedium: const TextStyle(
      fontSize: AppTextSizes.greeting,
      height: 1.25,
      fontWeight: FontWeight.w500,
      color: AppColors.textPrimary,
    ),
    titleMedium: const TextStyle(
      fontSize: AppTextSizes.body,
      fontWeight: FontWeight.w500,
      color: AppColors.textPrimary,
    ),
    bodyMedium: const TextStyle(
      fontSize: AppTextSizes.body,
      height: 1.4,
      color: AppColors.textPrimary,
    ),
    bodySmall: const TextStyle(
      fontSize: AppTextSizes.caption,
      color: AppColors.textMuted,
    ),
    labelLarge: const TextStyle(
      fontSize: AppTextSizes.chip,
      fontWeight: FontWeight.w500,
      color: AppColors.textPrimary,
    ),
  );

  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    canvasColor: AppColors.bg,
    textTheme: textTheme,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      foregroundColor: AppColors.textPrimary,
      titleTextStyle: TextStyle(
        fontSize: AppTextSizes.body,
        fontWeight: FontWeight.w500,
        color: AppColors.textPrimary,
      ),
    ),
    cardTheme: const CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: AppRadii.cardAll),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      hintStyle: const TextStyle(color: AppColors.textMuted),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      border: const OutlineInputBorder(
        borderRadius: AppRadii.pillAll,
        borderSide: BorderSide.none,
      ),
      enabledBorder: const OutlineInputBorder(
        borderRadius: AppRadii.pillAll,
        borderSide: BorderSide.none,
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: AppRadii.pillAll,
        borderSide: BorderSide(color: AppColors.accent),
      ),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.border, space: 1),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? AppColors.accent
            : AppColors.textMuted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? AppColors.accent.withValues(alpha: 0.35)
            : AppColors.surface,
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.surface,
      contentTextStyle: TextStyle(color: AppColors.textPrimary),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
