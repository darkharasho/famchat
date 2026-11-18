import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/providers.dart';
import '../../theme/tokens.dart';
import '../game_state.dart';
import '../providers.dart';
import 'board_view.dart';
import 'game_screen.dart';

/// A game in the timeline, where its `game` message landed: a live thumbnail,
/// the game's name and status, and Rematch on the chat's newest game that
/// started (inert ones never did) once it is over. Tap to open the board.
class GameCard extends ConsumerStatefulWidget {
  const GameCard({super.key, required this.chatId, required this.gameId});

  final String chatId, gameId;

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
    final mine = g.firstUserId == me || g.secondUserId == me;
    final newest = games.lastWhere((x) => !x.inert, orElse: () => g);
    final rematch = g.over && !viewer.readOnly && mine && newest.id == g.id;
    final status = viewer.status(g);
    final myTurn = !g.inert && !viewer.readOnly && g.toMoveUserId == me;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Material(
            color: s.surfaceContainerLowest,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Radii.md),
              side: BorderSide(color: s.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => openGame(context, chatId, gameId),
              child: Padding(
                padding: const EdgeInsets.all(Space.md),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: 84,
                      child: Opacity(
                        opacity: g.inert ? 0.5 : 1,
                        child: BoardView(
                          board: g.board,
                          mySide: me == null ? null : g.sideOf(me),
                          onPlay: (_) {},
                          thumbnail: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            g.type.title,
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            status,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: myTurn ? s.tertiary : s.onSurfaceVariant,
                              fontWeight: myTurn ? FontWeight.w600 : null,
                            ),
                          ),
                          if (rematch)
                            Padding(
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
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A new game of the same kind; whoever went second goes first. If a game
  /// is already running (the other player's rematch got there first), opens
  /// that one instead.
  Future<void> _rematch(GameState g) async {
    final sync = ref.read(chatSyncProvider);
    if (sync == null || _starting) return;
    final active = activeGame(ref.read(gamesProvider(chatId)));
    if (active != null) {
      unawaited(openGame(context, chatId, active.id));
      return;
    }
    setState(() => _starting = true);
    try {
      final id = await sync.startGame(chatId, g.type, first: g.secondUserId);
      if (mounted) unawaited(openGame(context, chatId, id));
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }
}
