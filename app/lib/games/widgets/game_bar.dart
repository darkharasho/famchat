import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/db/chat_db.dart';
import '../../chat/providers.dart';
import '../../theme/tokens.dart';
import '../game_state.dart';
import '../labels.dart';
import '../rules.dart';
import 'game_screen.dart';

/// The glyph for [t]; all but tic-tac-toe carry U+FE0E and need the
/// NotoSansSymbols2 family, so they never render as emoji.
String gameGlyph(GameType t) => switch (t) {
  GameType.chess => '\u265F\uFE0E',
  GameType.checkers => '\u26C0\uFE0E',
  GameType.fourinarow => '\u25CF\uFE0E',
  GameType.reversi => '\u25D0\uFE0E',
  GameType.dotsandboxes => '\u2B1A\uFE0E',
  GameType.tictactoe => '\u2715',
};

/// How long after my poke in a game I can poke again.
const pokeCooldown = Duration(minutes: 10);

/// Pinned under the header of a direct chat while [game] is unfinished:
/// `♟ Chess with Mom · Mom's turn  👉 Poke`. Tap to open the board. While
/// it's the other player's turn I can poke them, at most once per
/// [pokeCooldown].
class GameBar extends ConsumerStatefulWidget {
  const GameBar({super.key, required this.chatId, required this.game});

  final String chatId;
  final GameState game;

  @override
  ConsumerState<GameBar> createState() => _GameBarState();
}

class _GameBarState extends ConsumerState<GameBar> {
  /// Redraws when the cooldown's minutes left change.
  Timer? _tick;
  bool _sending = false;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _poke(GameState g, String opponentName) async {
    final sync = ref.read(chatSyncProvider);
    if (sync == null || _sending) return;
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await sync.sendMove(widget.chatId, g.id, g.type, g.ply, const {
        'type': 'poke',
      });
      messenger?.showSnackBar(SnackBar(content: Text('Poked $opponentName')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chatId = widget.chatId;
    final viewer = watchGameViewer(ref, chatId);
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final g = widget.game;
    final me = viewer.me;
    final opponent = me == g.firstUserId ? g.secondUserId : g.firstUserId;
    final myTurn = !viewer.readOnly && g.toMoveUserId == me;
    final canPoke =
        me != null &&
        !viewer.readOnly &&
        g.sideOf(me) != null &&
        g.toMoveUserId == opponent;
    final lastPoke = canPoke
        ? ref.watch(
            messagesProvider(chatId).select(
              (v) => lastPokeAt(v.value ?? const <MessageRow>[], g.id, me),
            ),
          )
        : null;
    _tick?.cancel();
    _tick = null;
    var left = Duration.zero;
    if (lastPoke != null) {
      final until = DateTime.fromMillisecondsSinceEpoch(lastPoke)
          .add(pokeCooldown);
      left = until.difference(DateTime.now());
    }
    final minutesLeft = (left.inMilliseconds / 60000).ceil();
    if (canPoke && minutesLeft > 0) {
      // The label changes when the time left drops below a whole minute.
      _tick = Timer(left - Duration(minutes: minutesLeft - 1), () {
        if (mounted) setState(() {});
      });
    }
    final opponentName = viewer.nameOf(opponent).split(' ').first;
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
                if (canPoke)
                  Padding(
                    padding: const EdgeInsets.only(left: Space.xs),
                    child: TextButton(
                      key: const Key('poke'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: const EdgeInsets.symmetric(
                          horizontal: Space.sm,
                        ),
                        foregroundColor: s.tertiary,
                      ),
                      onPressed: minutesLeft > 0 || _sending
                          ? null
                          : () => _poke(g, opponentName),
                      child: Text(
                        minutesLeft > 0 ? 'Poked · ${minutesLeft}m' : '👉 Poke',
                      ),
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
