import 'package:famchat/theme/app_theme.dart';
import 'package:famchat/theme/contrast.dart';
import 'package:famchat/theme/presets.dart';
import 'package:famchat/theme/tokens.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('contrast ratio matches WCAG endpoints', () {
    expect(contrastRatio(const Color(0xFF000000), const Color(0xFFFFFFFF)), closeTo(21, 0.01));
    expect(contrastRatio(const Color(0xFF777777), const Color(0xFF777777)), closeTo(1, 0.001));
  });

  // Readability is not optional in any preset: every text color, on everything it sits on, reads at
  // WCAG AA (4.5:1). Links double as the focus ring, so they clear 4.5:1 too, well over the 3:1 a
  // non-text indicator needs. The unread badge is checked as its text on its fill.
  for (final preset in ThemePreset.all) {
    for (final b in Brightness.values) {
      test('${preset.name} ${b.name}: every text color reads at 4.5:1 or better', () {
        final t = buildTheme(b, preset);
        final s = t.colorScheme;
        final k = t.extension<FamTokens>()!;
        final surfaces = {
          'surface': s.surface,
          'lowest': s.surfaceContainerLowest,
          'low': s.surfaceContainerLow,
          'container': s.surfaceContainer,
          'high': s.surfaceContainerHigh,
          'highest': s.surfaceContainerHighest,
          'backdrop': k.chatBackdrop,
        };
        final pairs = <String, (Color, Color)>{
          for (final e in surfaces.entries) ...{
            'onSurface/${e.key}': (s.onSurface, e.value),
            'onSurfaceVariant/${e.key}': (s.onSurfaceVariant, e.value),
            'tertiary (links, focus)/${e.key}': (s.tertiary, e.value),
            'error/${e.key}': (s.error, e.value),
          },
          'onPrimary/primary': (s.onPrimary, s.primary),
          'onSecondary/secondary': (s.onSecondary, s.secondary),
          'onTertiary/tertiary': (s.onTertiary, s.tertiary),
          'onPrimaryContainer': (s.onPrimaryContainer, s.primaryContainer),
          'onSecondaryContainer': (s.onSecondaryContainer, s.secondaryContainer),
          'onTertiaryContainer': (s.onTertiaryContainer, s.tertiaryContainer),
          'onErrorContainer': (s.onErrorContainer, s.errorContainer),
          'onInverseSurface': (s.onInverseSurface, s.inverseSurface),
          'inversePrimary (snack bar action)': (s.inversePrimary, s.inverseSurface),
          'mine text': (k.onMineBubble, k.mineBubble),
          'mine meta': (k.mineMeta, k.mineBubble),
          'mine text (gradient end)': (k.onMineBubble, k.mineBubbleEnd),
          'mine meta (gradient end)': (k.mineMeta, k.mineBubbleEnd),
          'theirs text': (k.onTheirsBubble, k.theirsBubble),
          'theirs meta': (k.theirsMeta, k.theirsBubble),
          'badge': (k.onBadge, k.badge),
        };
        final failures = [
          for (final e in pairs.entries)
            if (contrastRatio(e.value.$1, e.value.$2) < 4.5)
              '${e.key}: ${contrastRatio(e.value.$1, e.value.$2).toStringAsFixed(2)}',
        ];
        expect(failures, isEmpty, reason: '${preset.name} ${b.name}');
      });
    }
  }
}
