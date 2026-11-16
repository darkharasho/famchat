// Every family member gets one of eight hues, the same on every device: a stable hash of their
// user id (or a group's chat id) picks it.
import 'dart:ui' show Color;

import 'contrast.dart';

typedef PersonColor = ({Color bg, Color fg});

/// Marigold, coral, hydrangea, fern, plum, sky, rose, teal.
const personHues = <Color>[
  Color(0xFFF0A93B),
  Color(0xFFE9765F),
  Color(0xFF5A53D2),
  Color(0xFF3F9A69),
  Color(0xFF8A4797),
  Color(0xFF54A9DC),
  Color(0xFFDB6191),
  Color(0xFF1E7880),
];

/// FNV-1a over the UTF-16 code units of [key], folded onto the hues.
int personHueIndex(String key) {
  var h = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    h ^= unit;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h % personHues.length;
}

PersonColor personColor(String key) {
  final bg = personHues[personHueIndex(key)];
  return (bg: bg, fg: onColorFor(bg));
}
