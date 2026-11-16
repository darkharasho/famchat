// The one place FamChat's look is defined: colors, type, shapes and component defaults for the day
// (light) and evening (dark) themes. See docs/superpowers/plans/2026-11-16-ui-design.md.
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoPageTransitionsBuilder;
import 'package:material_ui/material_ui.dart';

import 'motion.dart';
import 'palette.dart';
import 'tokens.dart';

/// Headings, names, the wordmark.
const kDisplayFont = 'FamiljenGrotesk';

/// Everything you read: messages, labels, buttons.
const kBodyFont = 'AtkinsonHyperlegibleNext';

const _lightScheme = ColorScheme(
  brightness: Brightness.light,
  primary: Palette.dusk,
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFFE6E0F5),
  onPrimaryContainer: Palette.dusk,
  secondary: Palette.amberDeep,
  onSecondary: Color(0xFFFFFFFF),
  secondaryContainer: Palette.amber,
  onSecondaryContainer: Palette.amberInk,
  tertiary: Palette.hydrangea,
  onTertiary: Color(0xFFFFFFFF),
  tertiaryContainer: Palette.hydrangeaPale,
  onTertiaryContainer: Color(0xFF1E1878),
  error: Palette.error,
  onError: Color(0xFFFFFFFF),
  errorContainer: Color(0xFFFFDAD6),
  onErrorContainer: Color(0xFF410002),
  surface: Palette.lilac100,
  onSurface: Palette.ink,
  onSurfaceVariant: Palette.inkMuted,
  surfaceDim: Palette.lilac400,
  surfaceBright: Color(0xFFFFFFFF),
  surfaceContainerLowest: Color(0xFFFFFFFF),
  surfaceContainerLow: Palette.lilac50,
  surfaceContainer: Palette.lilac200,
  surfaceContainerHigh: Palette.lilac300,
  surfaceContainerHighest: Palette.lilac400,
  outline: Color(0xFF7D7590),
  outlineVariant: Palette.lilacLine,
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
  inverseSurface: Palette.dusk,
  onInverseSurface: Color(0xFFF3EFFA),
  inversePrimary: Palette.amber,
  surfaceTint: Color(0x00000000),
);

const _darkScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: Palette.amberEvening,
  onPrimary: Palette.amberInk,
  primaryContainer: Color(0xFF3E3460),
  onPrimaryContainer: Color(0xFFEDE6FF),
  secondary: Palette.amberEvening,
  onSecondary: Palette.amberInk,
  secondaryContainer: Color(0xFF4A3A12),
  onSecondaryContainer: Color(0xFFFFE0A3),
  tertiary: Palette.hydrangeaNight,
  onTertiary: Color(0xFF1E1878),
  tertiaryContainer: Color(0xFF3A3490),
  onTertiaryContainer: Color(0xFFE3E1FF),
  error: Palette.errorNight,
  onError: Color(0xFF690005),
  errorContainer: Color(0xFF93000A),
  onErrorContainer: Color(0xFFFFDAD6),
  surface: Palette.night100,
  onSurface: Palette.moon,
  onSurfaceVariant: Palette.moonMuted,
  surfaceDim: Palette.night50,
  surfaceBright: Palette.night500,
  surfaceContainerLowest: Palette.night50,
  surfaceContainerLow: Palette.night200,
  surfaceContainer: Palette.night300,
  surfaceContainerHigh: Palette.night400,
  surfaceContainerHighest: Palette.night500,
  outline: Color(0xFF91889F),
  outlineVariant: Palette.nightLine,
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
  inverseSurface: Palette.moon,
  onInverseSurface: Palette.ink,
  inversePrimary: Palette.dusk,
  surfaceTint: Color(0x00000000),
);

ColorScheme schemeFor(Brightness b) => b == Brightness.dark ? _darkScheme : _lightScheme;

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

ThemeData buildTheme(Brightness brightness) {
  final s = schemeFor(brightness);
  final dark = brightness == Brightness.dark;
  final text = _textTheme(s);
  final tokens = dark ? FamTokens.dark : FamTokens.light;
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
