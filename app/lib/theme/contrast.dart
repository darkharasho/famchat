import 'dart:math' as math;
import 'dart:ui' show Color;

import 'palette.dart';

double _channel(double c) => c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

/// WCAG relative luminance of an opaque color.
double luminance(Color c) => 0.2126 * _channel(c.r) + 0.7152 * _channel(c.g) + 0.0722 * _channel(c.b);

/// WCAG contrast ratio between two opaque colors (1 to 21).
double contrastRatio(Color a, Color b) {
  final la = luminance(a), lb = luminance(b);
  final hi = math.max(la, lb), lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

const _white = Color(0xFFFFFFFF);

/// White or ink, whichever reads better on [bg].
Color onColorFor(Color bg) => contrastRatio(_white, bg) >= contrastRatio(Palette.ink, bg) ? _white : Palette.ink;
