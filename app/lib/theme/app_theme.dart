// The one place FamChat's look is defined: colors, type, shapes and component defaults for the day
// (light) and evening (dark) themes. The colours come from a ThemePreset (presets.dart); the rest
// is the same in every preset. See docs/superpowers/plans/2026-11-16-ui-design.md and
// docs/superpowers/specs/2026-11-18-colour-themes-design.md.
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/services.dart' show rootBundle;
import 'package:material_ui/material_ui.dart';

import 'motion.dart';
import 'palette.dart';
import 'presets.dart';
import 'tokens.dart';

/// Headings, names, the wordmark.
const kDisplayFont = 'FamiljenGrotesk';

/// Everything you read: messages, labels, buttons.
const kBodyFont = 'AtkinsonHyperlegibleNext';

/// Adds the bundled fonts' SIL Open Font License texts, and the spelling word list's, to the app's
/// license page.
void registerFontLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final (family, file) in const [
      ('Familjen Grotesk', 'assets/fonts/OFL-FamiljenGrotesk.txt'),
      ('Atkinson Hyperlegible Next', 'assets/fonts/OFL-AtkinsonHyperlegibleNext.txt'),
      ('Noto Sans Symbols 2', 'assets/fonts/OFL-NotoSansSymbols2.txt'),
    ]) {
      yield LicenseEntryWithLineBreaks([family], await rootBundle.loadString(file));
    }
    yield LicenseEntryWithLineBreaks(['SCOWL word list (spell checking)'], await rootBundle.loadString('assets/spelling/LICENSE.txt'));
  });
}

/// The ColorScheme of [preset] (FamChat's own look by default) in brightness [b]. Error colours
/// are the same in every preset.
ColorScheme schemeFor(Brightness b, [ThemePreset preset = ThemePreset.fallback]) {
  final dark = b == Brightness.dark;
  final c = preset.colors(dark: dark);
  return ColorScheme(
    brightness: b,
    primary: c.primary,
    onPrimary: c.onPrimary,
    primaryContainer: c.primaryContainer,
    onPrimaryContainer: c.onPrimaryContainer,
    secondary: c.secondary,
    onSecondary: c.onSecondary,
    secondaryContainer: c.secondaryContainer,
    onSecondaryContainer: c.onSecondaryContainer,
    tertiary: c.tertiary,
    onTertiary: c.onTertiary,
    tertiaryContainer: c.tertiaryContainer,
    onTertiaryContainer: c.onTertiaryContainer,
    error: dark ? Palette.errorNight : Palette.error,
    onError: dark ? const Color(0xFF690005) : const Color(0xFFFFFFFF),
    errorContainer: dark ? const Color(0xFF93000A) : const Color(0xFFFFDAD6),
    onErrorContainer: dark ? const Color(0xFFFFDAD6) : const Color(0xFF410002),
    surface: c.surface,
    onSurface: c.onSurface,
    onSurfaceVariant: c.onSurfaceVariant,
    surfaceDim: c.surfaceDim,
    surfaceBright: c.surfaceBright,
    surfaceContainerLowest: c.surfaceContainerLowest,
    surfaceContainerLow: c.surfaceContainerLow,
    surfaceContainer: c.surfaceContainer,
    surfaceContainerHigh: c.surfaceContainerHigh,
    surfaceContainerHighest: c.surfaceContainerHighest,
    outline: c.outline,
    outlineVariant: c.outlineVariant,
    shadow: const Color(0xFF000000),
    scrim: const Color(0xFF000000),
    inverseSurface: c.inverseSurface,
    onInverseSurface: c.onInverseSurface,
    inversePrimary: c.inversePrimary,
    surfaceTint: const Color(0x00000000),
  );
}

/// The chat colours of [preset] in brightness [b]. Presence is the same in every preset; the
/// unread badge wears the own-message colour, and their messages use the body and muted inks.
FamTokens tokensFor(Brightness b, [ThemePreset preset = ThemePreset.fallback]) {
  final dark = b == Brightness.dark;
  final c = preset.colors(dark: dark);
  return FamTokens(
    mineBubble: c.mineBubble,
    mineBubbleEnd: c.mineBubbleEnd,
    onMineBubble: c.onMineBubble,
    mineMeta: c.mineMeta,
    theirsBubble: c.theirsBubble,
    onTheirsBubble: c.onSurface,
    theirsMeta: c.onSurfaceVariant,
    theirsBorder: c.theirsBorder,
    chatBackdrop: c.chatBackdrop,
    presence: dark ? Palette.fernNight : Palette.fern,
    badge: c.mineBubble,
    onBadge: c.onMineBubble,
  );
}

TextTheme _textTheme(ColorScheme s) {
  TextStyle display(double size, FontWeight w, {double height = 1.2, double spacing = 0}) => TextStyle(
        fontFamily: kDisplayFont,
        fontSize: size,
        fontWeight: w,
        height: height,
        letterSpacing: spacing,
        color: s.onSurface,
      );
  TextStyle body(double size, FontWeight w, {double height = 1.4, double spacing = 0}) => TextStyle(
        fontFamily: kBodyFont,
        fontSize: size,
        fontWeight: w,
        height: height,
        letterSpacing: spacing,
        color: s.onSurface,
      );
  return TextTheme(
    displayLarge: display(52, FontWeight.w700, height: 1.08, spacing: -1),
    displayMedium: display(44, FontWeight.w700, height: 1.1, spacing: -0.8),
    displaySmall: display(36, FontWeight.w700, height: 1.12, spacing: -0.5),
    headlineLarge: display(32, FontWeight.w700, spacing: -0.4),
    headlineMedium: display(28, FontWeight.w700, spacing: -0.3),
    headlineSmall: display(24, FontWeight.w600, spacing: -0.2),
    titleLarge: display(21, FontWeight.w600, spacing: -0.1),
    titleMedium: display(17, FontWeight.w600),
    titleSmall: display(15, FontWeight.w600),
    bodyLarge: body(16, FontWeight.w400),
    bodyMedium: body(15, FontWeight.w400),
    bodySmall: body(13, FontWeight.w400, height: 1.35, spacing: 0.1).copyWith(color: s.onSurfaceVariant),
    labelLarge: body(15, FontWeight.w700, height: 1.2, spacing: 0.1),
    labelMedium: body(13, FontWeight.w500, height: 1.25, spacing: 0.1),
    labelSmall: body(12, FontWeight.w500, height: 1.25, spacing: 0.2),
  );
}

const _transitions = PageTransitionsTheme(builders: {
  TargetPlatform.android: ReducedMotionTransitionsBuilder(FadeForwardsPageTransitionsBuilder()),
  TargetPlatform.fuchsia: ReducedMotionTransitionsBuilder(FadeForwardsPageTransitionsBuilder()),
  TargetPlatform.linux: ReducedMotionTransitionsBuilder(FadeForwardsPageTransitionsBuilder()),
  TargetPlatform.windows: ReducedMotionTransitionsBuilder(FadeForwardsPageTransitionsBuilder()),
  TargetPlatform.iOS: ReducedMotionTransitionsBuilder(CupertinoPageTransitionsBuilder()),
  TargetPlatform.macOS: ReducedMotionTransitionsBuilder(CupertinoPageTransitionsBuilder()),
});

/// The whole theme for [preset] (FamChat's own look by default) in [brightness].
ThemeData buildTheme(Brightness brightness, [ThemePreset preset = ThemePreset.fallback]) {
  final s = schemeFor(brightness, preset);
  final dark = brightness == Brightness.dark;
  final text = _textTheme(s);
  final tokens = tokensFor(brightness, preset);
  final pill = WidgetStatePropertyAll<OutlinedBorder>(const StadiumBorder());
  const buttonSize = WidgetStatePropertyAll(Size(64, 48));
  const buttonPadding = WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: Space.xl, vertical: Space.md));
  final field = OutlineInputBorder(
    borderRadius: BorderRadius.circular(Radii.md),
    borderSide: BorderSide(color: s.outlineVariant),
  );
  final raised = dark ? s.surfaceContainerHigh : s.surfaceContainerLowest;
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: s,
    fontFamily: kBodyFont,
    textTheme: text,
    primaryTextTheme: text.apply(bodyColor: s.onPrimary, displayColor: s.onPrimary),
    scaffoldBackgroundColor: s.surface,
    canvasColor: s.surface,
    extensions: [tokens],
    pageTransitionsTheme: _transitions,
    visualDensity: VisualDensity.standard,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: s.surface,
      foregroundColor: s.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleSpacing: Space.lg,
      titleTextStyle: text.titleLarge,
      toolbarHeight: 60,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        shape: pill,
        minimumSize: buttonSize,
        padding: buttonPadding,
        textStyle: WidgetStatePropertyAll(text.labelLarge),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        shape: pill,
        minimumSize: buttonSize,
        padding: buttonPadding,
        textStyle: WidgetStatePropertyAll(text.labelLarge),
        foregroundColor: WidgetStatePropertyAll(s.onSurface),
        side: WidgetStateProperty.resolveWith((states) => BorderSide(
              color: states.contains(WidgetState.disabled) ? s.outlineVariant : s.outline,
            )),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        shape: pill,
        minimumSize: const WidgetStatePropertyAll(Size(48, 44)),
        textStyle: WidgetStatePropertyAll(text.labelLarge),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled) ? s.onSurface.withValues(alpha: 0.38) : s.tertiary,
        ),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: tokens.badge,
      foregroundColor: tokens.onBadge,
      elevation: 2,
      highlightElevation: 4,
      shape: const StadiumBorder(),
      extendedTextStyle: text.labelLarge,
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: raised,
      contentPadding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: 14),
      border: field,
      enabledBorder: field,
      disabledBorder: field.copyWith(borderSide: BorderSide(color: s.outlineVariant.withValues(alpha: 0.5))),
      focusedBorder: field.copyWith(borderSide: BorderSide(color: s.tertiary, width: 2)),
      errorBorder: field.copyWith(borderSide: BorderSide(color: s.error)),
      focusedErrorBorder: field.copyWith(borderSide: BorderSide(color: s.error, width: 2)),
      labelStyle: text.bodyLarge?.copyWith(color: s.onSurfaceVariant),
      floatingLabelStyle: text.bodyMedium?.copyWith(color: s.tertiary, fontWeight: FontWeight.w500),
      hintStyle: text.bodyLarge?.copyWith(color: s.onSurfaceVariant),
      helperStyle: text.bodySmall,
      helperMaxLines: 3,
      errorMaxLines: 3,
    ),
    cardTheme: CardThemeData(
      color: raised,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
        side: BorderSide(color: s.outlineVariant),
      ),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: Space.lg),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
      iconColor: s.onSurfaceVariant,
      selectedColor: s.onSurface,
      selectedTileColor: s.primaryContainer.withValues(alpha: dark ? 0.55 : 0.7),
      titleTextStyle: text.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
      subtitleTextStyle: text.bodyMedium?.copyWith(color: s.onSurfaceVariant),
      minVerticalPadding: Space.md,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: raised,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      titleTextStyle: text.headlineSmall,
      contentTextStyle: text.bodyLarge?.copyWith(color: s.onSurfaceVariant),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: raised,
      modalBackgroundColor: raised,
      showDragHandle: true,
      dragHandleColor: s.outline,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: s.inverseSurface,
      contentTextStyle: text.bodyMedium?.copyWith(color: s.onInverseSurface),
      actionTextColor: s.inversePrimary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
      width: null,
    ),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: BorderSide(color: s.outlineVariant),
      backgroundColor: raised,
      labelStyle: text.labelMedium,
    ),
    dividerTheme: DividerThemeData(color: s.outlineVariant, space: 1, thickness: 1),
    badgeTheme: BadgeThemeData(
      backgroundColor: tokens.badge,
      textColor: tokens.onBadge,
      textStyle: text.labelSmall?.copyWith(fontWeight: FontWeight.w700),
      largeSize: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: dark ? s.primary : s.tertiary,
      linearTrackColor: s.surfaceContainerHigh,
      circularTrackColor: Colors.transparent,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: s.inverseSurface, borderRadius: BorderRadius.circular(Radii.sm)),
      textStyle: text.labelMedium?.copyWith(color: s.onInverseSurface),
      waitDuration: const Duration(milliseconds: 400),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: raised,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
      textStyle: text.bodyLarge,
    ),
    checkboxTheme: CheckboxThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.xs))),
  );
}
