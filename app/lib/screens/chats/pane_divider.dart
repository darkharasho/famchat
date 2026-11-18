// The line between the chat list and the open chat on wide windows. Drag it to resize the list;
// double-click to put it back to the default width.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../settings/list_width.dart';

class PaneDivider extends ConsumerStatefulWidget {
  const PaneDivider({super.key, required this.shownWidth});

  /// The list's width on screen now (the asked-for width after clamping to the window).
  final double shownWidth;

  /// The strip that takes the drag, wider than the 1px line it draws.
  static const grabWidth = 9.0;

  @override
  ConsumerState<PaneDivider> createState() => _PaneDividerState();
}

class _PaneDividerState extends ConsumerState<PaneDivider> {
  bool _hover = false;
  bool _dragging = false;
  double _startWidth = 0;
  double _startX = 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = _hover || _dragging;
    final notifier = ref.read(listWidthProvider.notifier);
    return Semantics(
      label: 'Resize chat list',
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: notifier.reset,
          // Measured from where the press began, so the drag's start threshold isn't lost.
          onHorizontalDragDown: (d) {
            _startWidth = widget.shownWidth;
            _startX = d.globalPosition.dx;
          },
          onHorizontalDragStart: (_) => setState(() => _dragging = true),
          onHorizontalDragUpdate: (d) => notifier.drag(_startWidth + d.globalPosition.dx - _startX),
          onHorizontalDragEnd: (_) {
            setState(() => _dragging = false);
            notifier.save();
          },
          onHorizontalDragCancel: () => setState(() => _dragging = false),
          child: SizedBox(
            width: PaneDivider.grabWidth,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: active ? 3 : 1,
                color: active ? scheme.primary.withValues(alpha: 0.6) : Theme.of(context).dividerColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
