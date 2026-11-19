import 'package:material_ui/material_ui.dart';

import '../../theme/motion.dart';
import '../rules.dart';

/// Board colours derived from the theme, so boards follow light and dark mode.
class BoardColors {
  const BoardColors._({
    required this.light,
    required this.dark,
    required this.lastMove,
    required this.selected,
    required this.target,
    required this.check,
  });

  factory BoardColors.of(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final isDark = s.brightness == Brightness.dark;
    return BoardColors._(
      light: isDark
          ? Color.lerp(
              Color.lerp(s.surface, s.onSurface, 0.55),
              s.primary,
              0.16,
            )!
          : Color.lerp(const Color(0xFFFFFFFF), s.primary, 0.10)!,
      dark: isDark
          ? Color.lerp(s.surfaceContainerHighest, s.primary, 0.32)!
          : Color.lerp(const Color(0xFFFFFFFF), s.primary, 0.42)!,
      lastMove: s.tertiary.withValues(alpha: 0.32),
      selected: s.tertiary,
      // Dark mode's squares are dark: a light mark reads on both colours.
      target: isDark
          ? s.onSurface.withValues(alpha: 0.6)
          : const Color(0xFF000000).withValues(alpha: 0.24),
      check: s.error.withValues(alpha: 0.45),
    );
  }

  final Color light, dark, lastMove, selected, target, check;
}

enum TargetMark { none, dot, ring }

/// A board view that plays each new move out once. [clock] rests at 1
/// (nothing playing); [playMove] runs it from 0. Views read [clock] in an
/// [AnimatedBuilder] and draw the move part-way through.
abstract class MoveMotionState<T extends StatefulWidget> extends State<T>
    with SingleTickerProviderStateMixin<T> {
  late final AnimationController clock = AnimationController(
    vsync: this,
    value: 1,
  );

  /// Whether a move is playing out.
  bool get moving => clock.isAnimating;

  /// Plays a move over [ms] milliseconds. Returns false (and plays nothing)
  /// when the platform asks for less motion.
  bool playMove(int ms) {
    if (Motion.reduced(context)) {
      clock.value = 1;
      return false;
    }
    clock.duration = Duration(milliseconds: ms);
    clock.forward(from: 0);
    return true;
  }

  /// The clock's progress through [start]..[end] (fractions of the move),
  /// eased by [curve].
  double phase(double start, double end, [Curve curve = Curves.linear]) {
    final t = clock.value;
    if (t <= start) return 0;
    if (t >= end) return 1;
    return curve.transform((t - start) / (end - start));
  }

  @override
  void dispose() {
    clock.dispose();
    super.dispose();
  }
}

/// A lighter and a darker shade of [c], for drawn discs.
(Color, Color) discShades(Color c) => (
  Color.lerp(c, const Color(0xFFFFFFFF), 0.38)!,
  Color.lerp(c, const Color(0xFF000000), 0.32)!,
);

/// A round disc lit from the top left: [color] with soft radial shading, an
/// inner rim and a small shadow. [border] rings it (the winning four).
class ShadedDisc extends StatelessWidget {
  const ShadedDisc({
    super.key,
    required this.color,
    this.border,
    this.rim = true,
  });

  final Color color;
  final BoxBorder? border;
  final bool rim;

  @override
  Widget build(BuildContext context) {
    final (hi, lo) = discShades(color);
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: border,
        gradient: RadialGradient(
          center: const Alignment(-0.35, -0.4),
          radius: 0.95,
          colors: [hi, color, lo],
          stops: const [0, 0.55, 1],
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x40000000),
            blurRadius: 2,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: rim
          ? FractionallySizedBox(
              widthFactor: 0.64,
              heightFactor: 0.64,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    center: const Alignment(0.3, 0.35),
                    radius: 0.9,
                    colors: [
                      color.withValues(alpha: 0),
                      lo.withValues(alpha: 0.35),
                    ],
                  ),
                ),
              ),
            )
          : null,
    );
  }
}

/// Whether two outcomes are the same result (Outcome has no ==).
bool sameOutcome(Outcome? a, Outcome? b) =>
    a?.winner == b?.winner && a?.reason == b?.reason;

/// The board's outer shape: a square with rounded corners. [cell] builds the
/// square at display [row] (0 at the top) and [col] (0 at the left).
class BoardGrid extends StatelessWidget {
  const BoardGrid({
    super.key,
    required this.size,
    required this.cell,
    this.thumbnail = false,
    this.background,
    this.gap = 0,
  });

  final int size;
  final Widget Function(int row, int col) cell;
  final bool thumbnail;
  final Color? background;
  final double gap;

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 1,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(thumbnail ? 6 : 14),
      child: ColoredBox(
        color: background ?? const Color(0x00000000),
        child: Padding(
          padding: EdgeInsets.all(gap),
          child: Column(
            children: [
              for (var r = 0; r < size; r++)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(top: r == 0 ? 0 : gap),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var c = 0; c < size; c++)
                          Expanded(
                            child: Padding(
                              padding: EdgeInsets.only(left: c == 0 ? 0 : gap),
                              child: cell(r, c),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// One flat square with its overlays: a tint (last move, check, winning
/// line), the [piece], a target mark and a selection outline.
class BoardSquare extends StatelessWidget {
  const BoardSquare({
    super.key,
    required this.color,
    this.tint,
    this.piece,
    this.target = TargetMark.none,
    this.targetColor = const Color(0x3D000000),
    this.outline,
    this.onTap,
    this.label,
    this.overlay,
    this.radius = 0,
  });

  final Color color;
  final Color? tint, outline;
  final Widget? piece, overlay;
  final TargetMark target;
  final Color targetColor;
  final VoidCallback? onTap;
  final String? label;
  final double radius;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    button: onTap != null,
    excludeSemantics: true,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: LayoutBuilder(
        builder: (context, box) {
          final side = box.biggest.shortestSide;
          return DecoratedBox(
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(radius),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (tint != null)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: tint,
                      borderRadius: BorderRadius.circular(radius),
                    ),
                  ),
                ?overlay,
                ?piece,
                if (target == TargetMark.dot)
                  Center(
                    child: Container(
                      width: side * 0.3,
                      height: side * 0.3,
                      decoration: BoxDecoration(
                        color: targetColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                if (target == TargetMark.ring)
                  Padding(
                    padding: EdgeInsets.all(side * 0.04),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: targetColor,
                          width: side * 0.09,
                        ),
                      ),
                    ),
                  ),
                if (outline != null)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(radius),
                      border: Border.all(
                        color: outline!,
                        width: (side * 0.06).clamp(1.5, 4),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

/// Above a board: each player's colour [swatch], name and optional score, the
/// viewer's own side ([mySide]) on the left (first's for spectators).
/// [names] are the (first, second) display names ("You" for the viewer); null
/// shows colours and scores only. [describe] is the spoken label of a side,
/// given its name (if any).
class ScoreRow extends StatelessWidget {
  const ScoreRow({
    super.key,
    required this.mySide,
    required this.names,
    required this.swatch,
    required this.describe,
    this.score,
  });

  final Side? mySide;
  final (String, String)? names;
  final Widget Function(Side side) swatch;
  final String Function(Side side, String? name) describe;
  final int? Function(Side side)? score;

  String? _name(Side side) {
    final n = names;
    if (n == null) return null;
    final s = side == Side.first ? n.$1 : n.$2;
    return s.isEmpty ? null : s;
  }

  Widget _entry(BuildContext context, Side side) {
    final theme = Theme.of(context);
    final name = _name(side);
    final n = score?.call(side);
    return Semantics(
      label: describe(side, name),
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(dimension: 16, child: swatch(side)),
          if (name != null) ...[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                name,
                key: Key('name-${side.name}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: side == mySide ? FontWeight.w700 : null,
                ),
              ),
            ),
          ],
          if (n != null) ...[
            const SizedBox(width: 6),
            _Bump(
              value: n,
              child: Text(
                '$n',
                key: Key('count-${side.name}'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final left = mySide ?? Side.first;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(child: _entry(context, left)),
          const SizedBox(width: 12),
          Flexible(child: _entry(context, left.other)),
        ],
      ),
    );
  }
}

/// [child] grows and settles once whenever [value] changes, so a score that
/// moves is noticed.
class _Bump extends StatefulWidget {
  const _Bump({required this.value, required this.child});

  final int value;
  final Widget child;

  @override
  State<_Bump> createState() => _BumpState();
}

class _BumpState extends State<_Bump> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    value: 1,
  );

  @override
  void didUpdateWidget(_Bump old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && !Motion.reduced(context)) {
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (context, child) {
      final t = _c.value;
      // Up to 1.4x by a third of the way, then back.
      final up = t < 0.3
          ? Curves.easeOut.transform(t / 0.3)
          : 1 - Curves.easeInOut.transform((t - 0.3) / 0.7);
      return Transform.scale(scale: 1 + 0.4 * up, child: child);
    },
    child: widget.child,
  );
}
