// The members matching an `@name` being typed, above the composer.
import 'package:material_ui/material_ui.dart';

import '../../theme/tokens.dart';
import '../../widgets/person_avatar.dart';

/// Someone who can be @mentioned.
typedef Person = ({String id, String name});

class MentionSuggestions extends StatelessWidget {
  const MentionSuggestions({super.key, required this.people, required this.selected, required this.onPick});

  final List<Person> people;
  final int selected;
  final ValueChanged<Person> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    return Material(
      key: const Key('mention-suggestions'),
      color: s.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: BorderSide(color: s.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.xs),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final (i, p) in people.indexed)
            Semantics(
              selected: i == selected,
              child: InkWell(
                key: Key('mention-${p.id}'),
                onTap: () => onPick(p),
                child: Container(
                  color: i == selected ? s.secondaryContainer : null,
                  padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 6),
                  child: Row(children: [
                    PersonAvatar(label: p.name, colorKey: p.id, userId: p.id, radius: 14),
                    const SizedBox(width: Space.sm),
                    Expanded(
                      child: Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: i == selected ? s.onSecondaryContainer : s.onSurface,
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
