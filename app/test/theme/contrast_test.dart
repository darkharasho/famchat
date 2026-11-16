import 'package:famchat/theme/app_theme.dart';
import 'package:famchat/theme/contrast.dart';
import 'package:famchat/theme/tokens.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('contrast ratio matches WCAG endpoints', () {
    expect(contrastRatio(const Color(0xFF000000), const Color(0xFFFFFFFF)), closeTo(21, 0.01));
    expect(contrastRatio(const Color(0xFF777777), const Color(0xFF777777)), closeTo(1, 0.001));
  });

  for (final b in Brightness.values) {
    test('every text color in the ${b.name} theme reads at 4.5:1 or better', () {
      final t = buildTheme(b);
      final s = t.colorScheme;
      final k = t.extension<FamTokens>()!;
      final surfaces = {
        'surface': s.surface,
        'lowest': s.surfaceContainerLowest,
        'low': s.surfaceContainerLow,
        'container': s.surfaceContainer,
        'high': s.surfaceContainerHigh,
        'highest': s.surfaceContainerHighest,
      };
      final pairs = <String, (Color, Color)>{
        for (final e in surfaces.entries) ...{
          'onSurface/${e.key}': (s.onSurface, e.value),
          'onSurfaceVariant/${e.key}': (s.onSurfaceVariant, e.value),
          'tertiary (links)/${e.key}': (s.tertiary, e.value),
          'error/${e.key}': (s.error, e.value),
        },
        'onPrimary/primary': (s.onPrimary, s.primary),
        'onPrimaryContainer': (s.onPrimaryContainer, s.primaryContainer),
        'onSecondaryContainer': (s.onSecondaryContainer, s.secondaryContainer),
        'onTertiaryContainer': (s.onTertiaryContainer, s.tertiaryContainer),
        'onErrorContainer': (s.onErrorContainer, s.errorContainer),
        'onInverseSurface': (s.onInverseSurface, s.inverseSurface),
        'mine text': (k.onMineBubble, k.mineBubble),
        'mine meta': (k.mineMeta, k.mineBubble),
        'theirs text': (k.onTheirsBubble, k.theirsBubble),
        'theirs meta': (k.theirsMeta, k.theirsBubble),
        'meta on backdrop': (s.onSurfaceVariant, k.chatBackdrop),
        'badge': (k.onBadge, k.badge),
      };
      for (final e in pairs.entries) {
        final (fg, bg) = e.value;
        expect(contrastRatio(fg, bg), greaterThanOrEqualTo(4.5), reason: '${e.key} in ${b.name}');
      }
    });
  }
}
