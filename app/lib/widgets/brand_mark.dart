// FamChat's mark: a gable-roofed speech bubble with a lit window, on a dusk tile. Same geometry as
// tool/brand/make_brand.py (1024-unit artboard); keep the two in step.
import 'package:material_ui/material_ui.dart';

import '../theme/app_theme.dart';
import '../theme/palette.dart';

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 40, this.rim});

  final double size;

  /// A faint rim around the tile; by default only on the evening theme, where the dusk tile
  /// would otherwise sink into the background.
  final bool? rim;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'FamChat',
        image: true,
        child: CustomPaint(
          size: Size.square(size),
          painter: _MarkPainter(rim: rim ?? Theme.of(context).brightness == Brightness.dark),
        ),
      );
}

/// The mark and the name, for headers.
class Wordmark extends StatelessWidget {
  const Wordmark({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      ExcludeSemantics(child: BrandMark(size: size)),
      SizedBox(width: size * 0.36),
      Flexible(
        child: Text(
          'FamChat',
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: kDisplayFont,
            fontWeight: FontWeight.w700,
            fontSize: size * 0.82,
            height: 1,
            letterSpacing: -0.4,
            color: color,
          ),
        ),
      ),
    ]);
  }
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter({this.rim = false});

  final bool rim;

  @override
  void paint(Canvas canvas, Size size) => paintBrandMark(canvas, size, rim: rim);

  @override
  bool shouldRepaint(_MarkPainter oldDelegate) => oldDelegate.rim != rim;
}

final _house = Path()
  ..moveTo(512, 212)
  ..lineTo(780, 432)
  ..lineTo(780, 740)
  ..quadraticBezierTo(780, 780, 740, 780)
  ..lineTo(470, 780)
  ..lineTo(318, 884)
  ..lineTo(352, 780)
  ..lineTo(284, 780)
  ..quadraticBezierTo(244, 780, 244, 740)
  ..lineTo(244, 432)
  ..close();

const _houseColor = Color(0xFFF6F1FF);

/// The tile: a dusk sky, violet at the top, sunset along the bottom (tool/brand/make_brand.py SKY).
const _sky = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Color(0xFF2A2150), Color(0xFF5A2F6E), Color(0xFFB0456A), Color(0xFFE0704F)],
  stops: [0, 0.55, 0.85, 1],
);

/// Paints the mark, tile and all, filling [size]. Also draws the desktop tray icon
/// (lib/window/unread_badge_art.dart).
void paintBrandMark(Canvas canvas, Size size, {bool rim = false}) {
  canvas.save();
  canvas.scale(size.width / 1024, size.height / 1024);
  canvas.drawRRect(
    RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, 1024, 1024), const Radius.circular(232)),
    Paint()..shader = _sky.createShader(const Rect.fromLTWH(0, 0, 1024, 1024)),
  );
  if (rim) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(16, 16, 992, 992), const Radius.circular(220)),
      Paint()
        ..color = const Color(0x40FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 32,
    );
  }
  canvas
    ..translate(512, 512)
    ..scale(0.78)
    ..translate(-512, -548);
  _paintHouse(canvas, _houseColor);
  // The lit window: four rounded panes sharing one sunset glow.
  final glow = Paint()
    ..shader = const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Palette.windowGlow, Palette.windowGlowEnd],
    ).createShader(const Rect.fromLTWH(398, 462, 228, 200));
  for (final pane in const [
    Rect.fromLTWH(398, 462, 104, 90),
    Rect.fromLTWH(522, 462, 104, 90),
    Rect.fromLTWH(398, 572, 104, 90),
    Rect.fromLTWH(522, 572, 104, 90),
  ]) {
    canvas.drawRRect(RRect.fromRectAndRadius(pane, const Radius.circular(20)), glow);
  }
  canvas.restore();
}

void _paintHouse(Canvas canvas, Color color) {
  canvas.drawPath(_house, Paint()..color = color);
  canvas.drawPath(
    _house,
    Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 56
      ..strokeJoin = StrokeJoin.round,
  );
}

/// The mark without its tile: the house-shaped bubble in [color] with its window cut out, filling
/// [size]. For one-colour places such as the macOS menu bar.
void paintBrandGlyph(Canvas canvas, Size size, Color color) {
  // The house with its stroke spans x 216..808 and y 184..912 on the 1024 artboard.
  const left = 216.0, top = 184.0, w = 592.0, h = 728.0;
  final scale = size.height / h;
  canvas.save();
  canvas.saveLayer(Offset.zero & size, Paint());
  canvas
    ..translate((size.width - w * scale) / 2, 0)
    ..scale(scale)
    ..translate(-left, -top);
  _paintHouse(canvas, color);
  final hole = Paint()..blendMode = BlendMode.clear;
  for (final pane in const [
    Rect.fromLTWH(398, 462, 104, 90),
    Rect.fromLTWH(522, 462, 104, 90),
    Rect.fromLTWH(398, 572, 104, 90),
    Rect.fromLTWH(522, 572, 104, 90),
  ]) {
    canvas.drawRRect(RRect.fromRectAndRadius(pane, const Radius.circular(16)), hole);
  }
  canvas.restore();
  canvas.restore();
}
