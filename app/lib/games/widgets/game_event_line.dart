import 'package:material_ui/material_ui.dart';

import '../../theme/tokens.dart';
import 'game_screen.dart';

/// A game event in the timeline ("🏳 You resigned at Chess", "♟ Mom moved in Chess · Your turn"): a
/// quiet centred line, like the chat list's label for it. [suffix] follows [text] in bold tertiary; a
/// [poke] line is tinted. Tap to open the game.
class GameEventLine extends StatelessWidget {
  const GameEventLine({
    super.key,
    required this.chatId,
    required this.gameId,
    required this.text,
    this.suffix,
    this.poke = false,
  });

  final String chatId, gameId, text;
  final String? suffix;
  final bool poke;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final suffix = this.suffix;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Center(
        child: Material(
          color: poke ? s.tertiaryContainer : s.surfaceContainerLowest,
          shape: StadiumBorder(side: BorderSide(color: poke ? s.tertiaryContainer : s.outlineVariant)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => openGame(context, chatId, gameId),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 5),
              child: Text.rich(
                TextSpan(
                  text: text,
                  children: [
                    if (suffix != null)
                      TextSpan(
                        text: suffix,
                        style: TextStyle(color: s.tertiary, fontWeight: FontWeight.w700),
                      ),
                  ],
                ),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: poke ? s.onTertiaryContainer : s.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
