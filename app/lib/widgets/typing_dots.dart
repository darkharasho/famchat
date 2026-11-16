import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../theme/motion.dart';

/// Three dots that rise and fall in turn while someone types. Still when motion is reduced.
class TypingDots extends StatefulWidget {
  const TypingDots({super.key, this.color, this.size = 7});

  final Color? color;
  final double size;

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.reduced(context)) {
      _c.stop();
      _c.value = 0;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    final s = widget.size;
    return SizedBox(
      key: const Key('typing-dots'),
      width: s * 3 + s * 0.8 * 2,
      height: s * 2,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (var i = 0; i < 3; i++)
              Builder(builder: (context) {
                // Each dot lifts during its third of the cycle.
                final t = ((_c.value - i * 0.18) % 1.0);
                final lift = t < 0.4 ? math.sin(t / 0.4 * math.pi) : 0.0;
                final still = !_c.isAnimating;
                return Transform.translate(
                  offset: Offset(0, -lift * s * 0.6),
                  child: Container(
                    width: s,
                    height: s,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: still ? 0.7 : 0.45 + 0.55 * lift),
                      shape: BoxShape.circle,
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
