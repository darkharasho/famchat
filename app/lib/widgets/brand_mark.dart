// FamChat's mark: a gable-roofed speech bubble with a lit window, on a dusk tile. Same geometry as
// tool/brand/make_brand.py (1024-unit artboard); keep the two in step.
import 'package:material_ui/material_ui.dart';

import '../theme/app_theme.dart';
import '../theme/palette.dart';

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 40});

  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'FamChat',
        image: true,
        child: CustomPaint(size: Size.square(size), painter: const _MarkPainter()),
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
  const _MarkPainter();

  static final _house = Path()
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

  static const _houseColor = Color(0xFFF6F1FF);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 1024, size.height / 1024);
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, 1024, 1024), const Radius.circular(232)),
      Paint()..color = Palette.dusk,
    );
    canvas
      ..translate(512, 512)
      ..scale(0.78)
      ..translate(-512, -548);
    canvas.drawPath(_house, Paint()..color = _houseColor);
    canvas.drawPath(
      _house,
      Paint()
        ..color = _houseColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 56
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(398, 462, 228, 200), const Radius.circular(24)),
      Paint()..color = Palette.amber,
    );
    final mullion = Paint()
      ..color = Palette.dusk
      ..strokeWidth = 20;
    canvas
      ..drawLine(const Offset(512, 462), const Offset(512, 662), mullion)
      ..drawLine(const Offset(398, 562), const Offset(626, 562), mullion);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MarkPainter oldDelegate) => false;
}
