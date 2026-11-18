import 'package:material_ui/material_ui.dart';

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
      target: const Color(0xFF000000).withValues(alpha: 0.24),
      check: s.error.withValues(alpha: 0.45),
    );
  }

  final Color light, dark, lastMove, selected, target, check;
}

enum TargetMark { none, dot, ring }

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
