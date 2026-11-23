// Porch light, FamChat's own look, is the default preset. The schemes below freeze it (since the
// 2026-11-23 sunset accents) so an accidental change shows up; FamTokens.light and .dark are its
// tokens.
import 'package:famchat/theme/app_theme.dart';
import 'package:famchat/theme/contrast.dart';
import 'package:famchat/theme/palette.dart';
import 'package:famchat/theme/presets.dart';
import 'package:famchat/theme/tokens.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _oldLight = ColorScheme(
  brightness: Brightness.light,
  primary: Palette.dusk,
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFFE6E0F5),
  onPrimaryContainer: Palette.dusk,
  secondary: Palette.brick,
  onSecondary: Color(0xFFFFFFFF),
  secondaryContainer: Palette.blush,
  onSecondaryContainer: Palette.blushInk,
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
  inversePrimary: Palette.ember,
  surfaceTint: Color(0x00000000),
);

const _oldDark = ColorScheme(
  brightness: Brightness.dark,
  primary: Palette.ember,
  onPrimary: Palette.emberInk,
  primaryContainer: Color(0xFF3E3460),
  onPrimaryContainer: Color(0xFFEDE6FF),
  secondary: Palette.ember,
  onSecondary: Palette.emberInk,
  secondaryContainer: Palette.plumNight,
  onSecondaryContainer: Palette.plumNightInk,
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

Map<String, Color> _tokenColors(FamTokens t) => {
  'mineBubble': t.mineBubble,
  'mineBubbleEnd': t.mineBubbleEnd,
  'onMineBubble': t.onMineBubble,
  'mineMeta': t.mineMeta,
  'theirsBubble': t.theirsBubble,
  'onTheirsBubble': t.onTheirsBubble,
  'theirsMeta': t.theirsMeta,
  'theirsBorder': t.theirsBorder,
  'chatBackdrop': t.chatBackdrop,
  'presence': t.presence,
  'badge': t.badge,
  'onBadge': t.onBadge,
};

void main() {
  test('Porch light is the default and the fallback', () {
    expect(ThemePreset.fallback, same(ThemePreset.porchLight));
    expect(ThemePreset.all.first, same(ThemePreset.porchLight));
  });

  test('Porch light color schemes are unchanged', () {
    expect(schemeFor(Brightness.light), _oldLight);
    expect(schemeFor(Brightness.dark), _oldDark);
    expect(schemeFor(Brightness.light, ThemePreset.porchLight), _oldLight);
    expect(schemeFor(Brightness.dark, ThemePreset.porchLight), _oldDark);
  });

  test('Porch light chat tokens are unchanged', () {
    expect(_tokenColors(tokensFor(Brightness.light)), _tokenColors(FamTokens.light));
    expect(_tokenColors(tokensFor(Brightness.dark)), _tokenColors(FamTokens.dark));
  });

  test('buildTheme defaults to Porch light', () {
    for (final b in Brightness.values) {
      final t = buildTheme(b);
      final dark = b == Brightness.dark;
      expect(t.colorScheme, dark ? _oldDark : _oldLight);
      expect(_tokenColors(t.extension<FamTokens>()!), _tokenColors(dark ? FamTokens.dark : FamTokens.light));
      expect(buildTheme(b, ThemePreset.porchLight).colorScheme, t.colorScheme);
    }
  });

  test('preset ids and names are unique; an unknown id falls back to the default', () {
    expect(ThemePreset.all.map((p) => p.id).toSet(), hasLength(ThemePreset.all.length));
    expect(ThemePreset.all.map((p) => p.name).toSet(), hasLength(ThemePreset.all.length));
    for (final p in ThemePreset.all) {
      expect(ThemePreset.byId(p.id), same(p));
    }
    expect(ThemePreset.byId('no-such-theme'), same(ThemePreset.porchLight));
    expect(ThemePreset.byId(null), same(ThemePreset.porchLight));
  });

  test('every preset has a lighter day version and a darker evening one', () {
    for (final p in ThemePreset.all) {
      expect(buildTheme(Brightness.light, p).brightness, Brightness.light);
      expect(buildTheme(Brightness.dark, p).brightness, Brightness.dark);
      expect(luminance(p.light.surface), greaterThan(0.8), reason: p.name);
      expect(luminance(p.dark.surface), lessThan(0.02), reason: p.name);
    }
  });
}
