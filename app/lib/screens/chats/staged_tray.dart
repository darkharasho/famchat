// The staged photos and videos above the composer: a thumbnail each with ✕, and + to add more.
import 'package:material_ui/material_ui.dart';

import '../../media/photo_picker.dart';
import '../../theme/tokens.dart';

class StagedTray extends StatelessWidget {
  const StagedTray({super.key, required this.items, required this.onRemove, required this.onAdd});

  final List<PickedMedia> items;
  final ValueChanged<int> onRemove;
  final VoidCallback onAdd;

  static const _size = 64.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final n = items.length;
    return Column(key: const Key('staged-tray'), crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        height: _size + Space.sm,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(top: Space.sm, right: Space.sm),
          clipBehavior: Clip.none,
          children: [
            for (final (i, item) in items.indexed)
              Padding(
                padding: const EdgeInsets.only(right: Space.sm),
                child: Stack(clipBehavior: Clip.none, children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(Radii.sm),
                    child: SizedBox.square(dimension: _size, child: _tile(item, scheme)),
                  ),
                  Positioned(
                    top: -6,
                    right: -6,
                    child: Semantics(
                      button: true,
                      label: 'Remove',
                      child: GestureDetector(
                        key: Key('staged-remove-$i'),
                        onTap: () => onRemove(i),
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: scheme.inverseSurface,
                            shape: BoxShape.circle,
                            border: Border.all(color: scheme.surface, width: 2),
                          ),
                          child: Icon(Icons.close_rounded, size: 13, color: scheme.onInverseSurface),
                        ),
                      ),
                    ),
                  ),
                ]),
              ),
            Tooltip(
              message: 'Add more',
              child: InkWell(
                key: const Key('staged-add'),
                onTap: onAdd,
                borderRadius: BorderRadius.circular(Radii.sm),
                child: Container(
                  width: _size,
                  height: _size,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(Radii.sm),
                    border: Border.all(color: scheme.outlineVariant, width: 2),
                  ),
                  child: Icon(Icons.add_rounded, color: scheme.onSurfaceVariant),
                ),
              ),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: Space.xs),
        child: Text(
          '$n ${n == 1 ? 'item' : 'items'} · your message goes with them',
          style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
    ]);
  }

  Widget _tile(PickedMedia item, ColorScheme scheme) => switch (item) {
        PickedPhoto(:final bytes) => Image.memory(
            bytes,
            fit: BoxFit.cover,
            cacheWidth: 192,
            errorBuilder: (_, _, _) => ColoredBox(
              color: scheme.surfaceContainerHighest,
              child: Icon(Icons.image_outlined, color: scheme.onSurfaceVariant),
            ),
          ),
        PickedVideo() => ColoredBox(
            color: scheme.inverseSurface,
            child: Icon(Icons.play_arrow_rounded, color: scheme.onInverseSurface, semanticLabel: 'Video'),
          ),
      };
}
