// Pinned messages (docs/protocol.md "Pins"): the bar under the chat header, and the line in the
// timeline for each pin and unpin.
import 'package:material_ui/material_ui.dart';

import '../../theme/tokens.dart';

/// The newest pin first; each tap jumps to the one shown and then shows the next older one.
class PinBar extends StatefulWidget {
  const PinBar({super.key, required this.pins, required this.snippetOf, required this.onJump});

  /// Pinned message ids, newest pin first.
  final List<String> pins;
  final String Function(String id) snippetOf;
  final void Function(String id) onJump;

  @override
  State<PinBar> createState() => _PinBarState();
}

class _PinBarState extends State<PinBar> {
  int _index = 0;

  @override
  void didUpdateWidget(PinBar old) {
    super.didUpdateWidget(old);
    // A new pin (or one gone) starts again from the newest.
    if (old.pins.firstOrNull != widget.pins.firstOrNull || _index >= widget.pins.length) _index = 0;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final pins = widget.pins;
    final n = pins.length;
    final i = _index.clamp(0, n - 1);
    final id = pins[i];
    return Material(
      key: const Key('pin-bar'),
      color: s.surface,
      shape: Border(bottom: BorderSide(color: s.outlineVariant)),
      child: InkWell(
        onTap: () {
          widget.onJump(id);
          setState(() => _index = (i + 1) % n);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.sm),
          child: Row(children: [
            // One segment per pin, the one shown highlighted (newest at the bottom).
            Column(mainAxisSize: MainAxisSize.min, children: [
              for (var k = n - 1; k >= 0; k--)
                Container(
                  width: 3,
                  height: n == 1 ? 28 : 28 / n - 2,
                  margin: const EdgeInsets.symmetric(vertical: 1),
                  decoration: BoxDecoration(
                    color: k == i ? s.tertiary : s.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
            ]),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(
                  n == 1 ? 'Pinned message' : 'Pinned message ${n - i} of $n',
                  style: theme.textTheme.labelMedium?.copyWith(color: s.tertiary, fontWeight: FontWeight.w700),
                ),
                Text(
                  widget.snippetOf(id),
                  key: const Key('pin-bar-text'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ]),
            ),
            Icon(Icons.push_pin_outlined, size: 18, color: s.onSurfaceVariant),
          ]),
        ),
      ),
    );
  }
}

/// "Bob pinned a message", centered in the timeline; tapping jumps to the message.
class PinNoteLine extends StatelessWidget {
  const PinNoteLine({super.key, required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Center(
        child: Material(
          color: s.surfaceContainerLowest,
          shape: StadiumBorder(side: BorderSide(color: s.outlineVariant)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 5),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.push_pin_outlined, size: 14, color: s.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(text, style: theme.textTheme.labelMedium?.copyWith(color: s.onSurfaceVariant)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
