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
  GameType.gofish => '\u{1F0A0}',
  GameType.war => '\u{1F0A1}',
  GameType.landlord => '\u{1F3E0}\uFE0E',
};

/// How long after my poke in a game I can poke again.
const pokeCooldown = Duration(minutes: 10);

/// Pinned under the header of a direct chat while it has unfinished
/// [games] (long game first, from `activeGames`). One game fills the bar:
/// `♟ Chess with Mom · Mom's turn  👉 Poke  ›`. Two share it, split down the
/// middle: `🏠 Landlord · Mom's turn 👉 │ ✕ Tic-tac-toe · Your turn`. Each
/// part opens its own board.
class GameBar extends StatelessWidget {
  const GameBar({super.key, required this.chatId, required this.games})
    : assert(games.length > 0);

  final String chatId;
  final List<GameState> games;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final split = games.length > 1;
    Widget segment(GameState g) => GameBarSegment(
      key: Key('game-bar-${g.id}'),
      chatId: chatId,
      game: g,
      compact: split,
    );
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
        child: split
            ? IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: segment(games[0])),
                    VerticalDivider(
                      width: 1,
                      thickness: 1,
                      color: s.outlineVariant,
                    ),
                    Expanded(child: segment(games[1])),
                  ],
                ),
              )
            : segment(games.single),
      ),
    );
  }
}

/// One game's part of the [GameBar]: its glyph, title and turn, tappable to
/// open the board. While it's the other player's turn I can poke them, at
/// most once per [pokeCooldown]. [compact] (two games sharing the bar) drops
/// the opponent's name and the chevron and shrinks Poke to an icon whose
/// tooltip carries the cooldown.
class GameBarSegment extends ConsumerStatefulWidget {
  const GameBarSegment({
    super.key,
    required this.chatId,
    required this.game,
    required this.compact,
  });

  final String chatId;
  final GameState game;
  final bool compact;

  @override
  ConsumerState<GameBarSegment> createState() => _GameBarSegmentState();
}

class _GameBarSegmentState extends ConsumerState<GameBarSegment> {
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
    final compact = widget.compact;
    final pokeLabel = minutesLeft > 0 ? 'Poked · ${minutesLeft}m' : null;
    final onPoke = minutesLeft > 0 || _sending
        ? null
        : () => _poke(g, opponentName);
    return InkWell(
      onTap: () => openGame(context, chatId, g.id),
      child: Padding(
        padding: compact
            ? const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.xs, Space.sm)
            : const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.sm, Space.sm),
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
                      text: compact
                          ? ' ${g.type.title} · '
                          : ' ${g.type.title} with ${viewer.nameOf(opponent)} · ',
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
            if (canPoke && compact)
              IconButton(
                key: const Key('poke'),
                tooltip: pokeLabel ?? 'Poke',
                visualDensity: VisualDensity.compact,
                onPressed: onPoke,
                icon: Opacity(
                  opacity: onPoke == null ? 0.5 : 1,
                  child: const Text('👉'),
                ),
              )
            else if (canPoke)
              Padding(
                padding: const EdgeInsets.only(left: Space.xs),
                child: TextButton(
                  key: const Key('poke'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(horizontal: Space.sm),
                    foregroundColor: s.tertiary,
                  ),
                  onPressed: onPoke,
                  child: Text(pokeLabel ?? '👉 Poke'),
                ),
              ),
            if (!compact)
              Icon(Icons.chevron_right_rounded, color: s.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
