import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:famchat/window/unread_badge_art.dart';
import 'package:flutter_test/flutter_test.dart';

/// The straight RGBA pixel at ([x], [y]).
List<int> pixel(Uint8List rgba, int size, int x, int y) {
  final i = (y * size + x) * 4;
  return rgba.sublist(i, i + 4);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the badge reads nothing at 0, 1 to 9, then 9+', () {
    expect(badgeLabel(0), isNull);
    expect(badgeLabel(-2), isNull);
    expect(badgeLabel(1), '1');
    expect(badgeLabel(9), '9');
    expect(badgeLabel(10), '9+');
    expect(badgeLabel(250), '9+');
  });

  test('description and tooltip', () {
    expect(unreadDescription(0), '');
    expect(unreadDescription(3), '3 unread');
    expect(unreadDescription(42), '42 unread');
    expect(trayTooltip(0), 'FamChat');
    expect(trayTooltip(3), 'FamChat — 3 unread');
  });

  test('pixel formats for Windows (BGRA) and StatusNotifierItem (ARGB)', () {
    final rgba = Uint8List.fromList([1, 2, 3, 4, 10, 20, 30, 40]);
    expect(rgbaToBgra(rgba), [3, 2, 1, 4, 30, 20, 10, 40]);
    expect(rgbaToArgb(rgba), [4, 1, 2, 3, 40, 10, 20, 30]);
  });

  test('the overlay is a red disc on clear corners, at the size asked for', () async {
    for (final size in [16, 32]) {
      final image = await renderOverlayIcon('3', size);
      expect(image.width, size);
      final px = await straightRgba(image);
      image.dispose();
      expect(px.length, size * size * 4);
      expect(pixel(px, size, 0, 0)[3], 0);
      // The disc itself (drawn without a label, as the test font's glyphs are solid squares).
      final disc = await renderOverlayIcon('', size);
      final c = pixel(await straightRgba(disc), size, size ~/ 2, size ~/ 2);
      disc.dispose();
      expect(c, [(badgeRed.r * 255).round(), (badgeRed.g * 255).round(), (badgeRed.b * 255).round(), 255]);
    }
  });

  test('the tray icon has a badge in its lower right only when there is a count', () async {
    const size = 32;
    final plain = await renderTrayIcon(null, size);
    final badged = await renderTrayIcon('9+', size);
    final a = await straightRgba(plain), b = await straightRgba(badged);
    plain.dispose();
    badged.dispose();
    final badge = trayBadgeRect(const ui.Size(32, 32), '9+');
    final x = (badge.left + 2).toInt(), y = badge.center.dy.toInt();
    expect(pixel(b, size, x, y)[0], greaterThan(200)); // red
    expect(pixel(a, size, x, y)[0], lessThan(120)); // the mark's dusk tile
    // The top left is the mark either way.
    expect(pixel(a, size, 8, 8), pixel(b, size, 8, 8));
  });

  test('the macOS template glyph is black on clear', () async {
    final image = await renderTemplateGlyph(36);
    final px = await straightRgba(image);
    final png = await pngBytes(image);
    image.dispose();
    expect(pixel(px, 36, 0, 0)[3], 0);
    final center = pixel(px, 36, 18, 10); // the roof
    expect(center, [0, 0, 0, 255]);
    expect(png.sublist(1, 4), 'PNG'.codeUnits);
  });
}
