// The unread count on the desktop apps' taskbar, dock and tray: its wording, and the small icons
// the runners show (drawn here with dart:ui, so every platform gets the same art at the exact pixel
// sizes it asks for).
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../widgets/brand_mark.dart';

/// What a count badge reads: null at 0 (no badge), "1" to "9", then "9+".
String? badgeLabel(int count) => count <= 0 ? null : (count > 9 ? '9+' : '$count');

/// The spoken form of the count, for the Windows taskbar overlay: "3 unread", or empty at 0.
String unreadDescription(int count) => count <= 0 ? '' : '$count unread';

/// The tray icon's tooltip: "FamChat", or "FamChat — 3 unread".
String trayTooltip(int count) => count <= 0 ? 'FamChat' : 'FamChat — ${unreadDescription(count)}';

/// The badge disc's colour; the label is white on it.
const badgeRed = Color(0xFFD92D3A);

/// Square pixel sizes rendered for the runners, which pick the one their DPI wants (16 at 100%,
/// 20 at 125%, 24 at 150%, 32 at 200%, …).
const iconSizes = [16, 20, 24, 32, 40, 48, 64];

/// Paints a badge reading [label] into [rect]: a disc, or a pill for wider labels.
void paintBadge(Canvas canvas, Rect rect, String label) {
  final r = rect.shortestSide / 2;
  canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(r)), Paint()..color = badgeRed);
  // Two characters need a smaller size to fit the same disc.
  final fontSize = rect.height * (label.length > 1 ? 0.64 : 0.8);
  final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
    textAlign: TextAlign.center,
    fontFamily: 'AtkinsonHyperlegibleNext',
    fontWeight: FontWeight.w700,
    fontSize: fontSize,
    height: 1,
    maxLines: 1,
  ))
    ..pushStyle(ui.TextStyle(color: const Color(0xFFFFFFFF), letterSpacing: label.length > 1 ? -fontSize * 0.06 : 0))
    ..addText(label);
  final paragraph = builder.build()..layout(ui.ParagraphConstraints(width: rect.width + r));
  canvas.drawParagraph(
    paragraph,
    Offset(rect.center.dx - (rect.width + r) / 2, rect.center.dy - paragraph.height / 2),
  );
  paragraph.dispose();
}

Future<ui.Image> _render(int size, void Function(Canvas canvas, Size size) paint) {
  final recorder = ui.PictureRecorder();
  final s = Size.square(size.toDouble());
  paint(Canvas(recorder, Offset.zero & s), s);
  final picture = recorder.endRecording();
  return picture.toImage(size, size).whenComplete(picture.dispose);
}

/// The Windows taskbar overlay: just the badge, filling a [size]-pixel square.
Future<ui.Image> renderOverlayIcon(String label, int size) =>
    _render(size, (canvas, s) => paintBadge(canvas, Offset.zero & s, label));

/// The badge's place on the tray icon: the lower right, about three fifths of the icon tall.
Rect trayBadgeRect(Size s, String label) {
  final h = (s.height * 0.62).roundToDouble();
  final w = label.length > 1 ? (s.width * 0.86).roundToDouble() : h;
  return Rect.fromLTWH(s.width - w, s.height - h, w, h);
}

/// The tray icon: FamChat's mark, with a badge reading [label] when there is one. A thin gap is cut
/// around the badge so it reads against the mark at 16 pixels.
Future<ui.Image> renderTrayIcon(String? label, int size) => _render(size, (canvas, s) {
      if (label == null) {
        paintBrandMark(canvas, s);
        return;
      }
      final badge = trayBadgeRect(s, label);
      canvas.saveLayer(Offset.zero & s, Paint());
      paintBrandMark(canvas, s);
      final gap = (s.height / 16).clamp(1.0, 4.0);
      canvas.drawRRect(
        RRect.fromRectAndRadius(badge.inflate(gap), Radius.circular(badge.height / 2 + gap)),
        Paint()..blendMode = BlendMode.clear,
      );
      canvas.restore();
      paintBadge(canvas, badge, label);
    });

/// The macOS menu bar's template image: the glyph in black on clear; macOS tints it.
Future<ui.Image> renderTemplateGlyph(int size) =>
    _render(size, (canvas, s) => paintBrandGlyph(canvas, s, const Color(0xFF000000)));

/// [image]'s pixels, row by row, as RGBA with straight (not premultiplied) alpha.
Future<Uint8List> straightRgba(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// [image] as PNG bytes.
Future<Uint8List> pngBytes(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// RGBA to BGRA, what a Windows 32-bit icon bitmap holds.
Uint8List rgbaToBgra(Uint8List rgba) {
  final out = Uint8List(rgba.length);
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    out[i] = rgba[i + 2];
    out[i + 1] = rgba[i + 1];
    out[i + 2] = rgba[i];
    out[i + 3] = rgba[i + 3];
  }
  return out;
}

/// RGBA to ARGB, byte for byte: the StatusNotifierItem pixmap format (32-bit ARGB, big-endian).
Uint8List rgbaToArgb(Uint8List rgba) {
  final out = Uint8List(rgba.length);
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    out[i] = rgba[i + 3];
    out[i + 1] = rgba[i];
    out[i + 2] = rgba[i + 1];
    out[i + 3] = rgba[i + 2];
  }
  return out;
}
