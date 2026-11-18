import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../theme/tokens.dart';
import '../game_state.dart';
import '../rules.dart';
import 'game_screen.dart';

/// The glyph for [t]; chess and checkers carry U+FE0E and need the
/// NotoSansSymbols2 family, so they never render as emoji.
String gameGlyph(GameType t) => switch (t) {
  GameType.chess => '\u265F\uFE0E',
  GameType.checkers => '\u26C0\uFE0E',
  GameType.fourinarow => '\u25CF\uFE0E',
  GameType.reversi => '\u25D0\uFE0E',
  GameType.tictactoe => '\u2715',
};

/// Pinned under the header of a direct chat while [game] is unfinished:
/// `♟ Chess with Mom · Your turn`. Tap to open the board.
class GameBar extends ConsumerWidget {
  const GameBar({super.key, required this.chatId, required this.game});

  final String chatId;
  final GameState game;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewer = watchGameViewer(ref, chatId);
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final g = game;
    final opponent = viewer.me == g.firstUserId
        ? g.secondUserId
        : g.firstUserId;
    final myTurn = !viewer.readOnly && g.toMoveUserId == viewer.me;
    final style = theme.textTheme.bodyMedium?.copyWith(color: s.onSurface);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.md, 0),
      child: Material(
        key: const Key('game-bar'),
        color: s.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          side: BorderSide(color: s.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => openGame(context, chatId, g.id),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.lg,
              Space.sm,
              Space.sm,
              Space.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      style: style,
                      children: [
                        TextSpan(
                          text: gameGlyph(g.type),
                          style: TextStyle(
                            fontFamily: g.type == GameType.tictactoe
                                ? null
                                : 'NotoSansSymbols2',
                            color: s.tertiary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        TextSpan(
                          text:
                              ' ${g.type.title} with ${viewer.nameOf(opponent)} · ',
                        ),
                        TextSpan(
                          text: viewer.status(g),
                          style: myTurn
                              ? TextStyle(
                                  color: s.tertiary,
                                  fontWeight: FontWeight.w600,
                                )
                              : null,
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: s.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
