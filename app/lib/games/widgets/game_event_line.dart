import 'package:material_ui/material_ui.dart';

import '../../theme/tokens.dart';
import 'game_screen.dart';

/// A game event in the timeline ("🏳 You resigned at Chess"): a quiet centred line, like the chat
/// list's label for it. Tap to open the game.
class GameEventLine extends StatelessWidget {
  const GameEventLine({super.key, required this.chatId, required this.gameId, required this.text});

  final String chatId, gameId, text;

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
            onTap: () => openGame(context, chatId, gameId),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 5),
              child: Text(text, style: theme.textTheme.labelMedium?.copyWith(color: s.onSurfaceVariant)),
            ),
          ),
        ),
      ),
    );
  }
}
