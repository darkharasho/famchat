import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../theme/tokens.dart';
import '../game_state.dart';
import '../providers.dart';
import '../rules.dart';
import 'board_parts.dart';
import 'board_view.dart';
import 'game_bar.dart';
import 'game_screen.dart';

/// A game in the timeline, where its `game` message landed, drawn like a link
/// embed: the game's glyph and name, the live position (last move
/// highlighted), the players with their colours (and score), the status, and
/// Rematch on the chat's newest game that started (inert ones never did) once
/// it is over. Tap anywhere to open the board.
class GameCard extends ConsumerStatefulWidget {
  const GameCard({super.key, required this.chatId, required this.gameId});

  final String chatId, gameId;

  /// The card's widest, as link previews; the board is this less padding.
  static const maxWidth = 320.0;

  @override
  ConsumerState<GameCard> createState() => _GameCardState();
}

class _GameCardState extends ConsumerState<GameCard> {
  var _starting = false;

  String get chatId => widget.chatId;
  String get gameId => widget.gameId;

  @override
  Widget build(BuildContext context) {
    final games = ref.watch(gamesProvider(chatId));
    final g = games.where((x) => x.id == gameId).firstOrNull;
    if (g == null) return const SizedBox.shrink();
    final viewer = watchGameViewer(ref, chatId);
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final me = viewer.me;
    final mySide = me == null ? null : g.sideOf(me);
    final rematch = canRematch(games, g, viewer);
    final status = viewer.status(g);
    final myTurn = !g.inert && !viewer.readOnly && g.toMoveUserId == me;
    final score = boardScore(g.board);
    final accent = myTurn ? s.tertiary : s.onSurface.withValues(alpha: 0.5);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: GameCard.maxWidth),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: const Key('game-card'),
              borderRadius: BorderRadius.circular(Radii.md),
              mouseCursor: SystemMouseCursors.click,
              onTap: () => openGame(context, chatId, gameId),
              child: Ink(
                decoration: BoxDecoration(
                  color: s.onSurface.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(Radii.md),
                  border: Border(left: BorderSide(color: accent, width: 3)),
                ),
                child: Opacity(
                  opacity: g.inert ? 0.5 : 1,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: gameGlyph(g.type),
                                style: TextStyle(
                                  fontFamily: g.type == GameType.tictactoe
                                      ? null
                                      : 'NotoSansSymbols2',
                                  color: s.tertiary,
                                ),
                              ),
                              TextSpan(text: ' ${g.type.title}'),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: Space.sm),
                        AspectRatio(
                          key: const Key('game-card-board'),
                          aspectRatio: boardAspectRatio(g.board),
                          child: BoardView(
                            board: g.board,
                            mySide: mySide,
                            onPlay: (_) {},
                            thumbnail: true,
                          ),
                        ),
                        const SizedBox(height: Space.sm),
                        ScoreRow(
                          mySide: mySide,
                          names: (
                            viewer.nameOf(g.firstUserId),
                            viewer.nameOf(g.secondUserId),
                          ),
                          swatch: (side) => sideSwatch(context, g.board, side),
                          describe: (side, name) =>
                              [?name, sideColourName(g.board, side)].join(': '),
                          score: score == null
                              ? null
                              : (side) =>
                                    side == Side.first ? score.$1 : score.$2,
                        ),
                        Text(
                          status,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: myTurn ? s.tertiary : s.onSurfaceVariant,
                            fontWeight: myTurn ? FontWeight.w600 : null,
                          ),
                        ),
                        if (rematch)
                          Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: Padding(
                              padding: const EdgeInsets.only(top: Space.xs),
                              child: TextButton(
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: Space.sm,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                ),
                                onPressed: _starting ? null : () => _rematch(g),
                                child: const Text('Rematch'),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Starts a rematch (or finds the game already running) and opens it.
  Future<void> _rematch(GameState g) async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      final id = await startRematch(ref, chatId, g);
      if (id != null && mounted) unawaited(openGame(context, chatId, id));
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }
}
