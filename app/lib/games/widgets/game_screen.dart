import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/db/chat_db.dart';
import '../../chat/providers.dart';
import '../../theme/tokens.dart';
import '../chess_board.dart';
import '../game_state.dart';
import '../providers.dart';
import 'board_view.dart';

/// Who is looking at a chat's games: me, names, and whether the chat is
/// read-only (a direct chat with someone no longer in a family with me).
class GameViewer {
  const GameViewer({
    required this.me,
    required this.users,
    required this.readOnly,
  });

  final String? me;
  final Map<String, UserRow> users;
  final bool readOnly;

  /// The display name the conversation uses ("You" for me).
  String nameOf(String userId) =>
      userId == me ? 'You' : users[userId]?.name ?? 'Someone';

  /// `Your turn`, `Mom's turn`, `You won`, `Mom won`, `Draw` or
  /// `Game not started`.
  String status(GameState g) {
    if (g.inert) return 'Game not started';
    final outcome = g.outcome;
    if (outcome != null) {
      final winner = g.winnerUserId;
      if (winner == null) return 'Draw';
      return winner == me ? 'You won' : '${nameOf(winner)} won';
    }
    final next = g.toMoveUserId!;
    return next == me ? 'Your turn' : "${nameOf(next)}'s turn";
  }
}

GameViewer watchGameViewer(WidgetRef ref, String chatId) {
  final chat = ref.watch(chatProvider(chatId)).value;
  final members =
      ref.watch(membersProvider(chatId)).value ?? const <MemberRow>[];
  final users = ref.watch(usersProvider).value ?? const <String, UserRow>{};
  final me = ref.watch(myUserIdProvider);
  final other = chat == null ? null : otherMember(chat, members, me);
  return GameViewer(
    me: me,
    users: users,
    readOnly: other != null && users[other]?.former == true,
  );
}

/// Opens game [gameId]'s board: a full-screen route on narrow windows, a
/// dialog (at most 560 wide) otherwise.
Future<void> openGame(BuildContext context, String chatId, String gameId) {
  final screen = GameScreen(chatId: chatId, gameId: gameId);
  final size = MediaQuery.sizeOf(context);
  if (size.width < 600) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => screen),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (context) {
      final s = MediaQuery.sizeOf(context);
      return Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 560,
            maxHeight: math.min(s.height - 48, 760),
          ),
          child: screen,
        ),
      );
    },
  );
}

const _reasons = {
  'checkmate': 'Checkmate',
  'stalemate': 'Stalemate',
  'threefold': 'Threefold repetition',
  'fifty_moves': 'Fifty-move rule',
  'insufficient': 'Not enough pieces to win',
  'no_moves': 'No moves left',
  'agreed': 'Draw agreed',
};

/// A game's board, live: plays, resignation and draw offers.
class GameScreen extends ConsumerStatefulWidget {
  const GameScreen({super.key, required this.chatId, required this.gameId});

  final String chatId, gameId;

  @override
  ConsumerState<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends ConsumerState<GameScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(ref.read(chatSyncProvider)?.markRead(widget.chatId));
      }
    });
  }

  void _send(GameState g, Map<String, Object?> action) {
    unawaited(
      ref
          .read(chatSyncProvider)
          ?.sendMove(widget.chatId, g.id, g.type, g.ply, action),
    );
  }

  Future<void> _confirm(
    GameState g, {
    required String title,
    required String body,
    required String action,
    required Map<String, Object?> move,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // Act on the game as it is now: a move may have arrived meanwhile.
    final now = ref
        .read(gamesProvider(widget.chatId))
        .where((x) => x.id == g.id)
        .firstOrNull;
    if (now == null || now.over) return;
    _send(now, move);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final g = ref
        .watch(gamesProvider(widget.chatId))
        .where((x) => x.id == widget.gameId)
        .firstOrNull;
    final viewer = watchGameViewer(ref, widget.chatId);
    if (g == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(
          child: SizedBox.square(
            dimension: 32,
            child: CircularProgressIndicator(),
          ),
        ),
      );
    }
    final me = viewer.me;
    final mySide = me == null ? null : g.sideOf(me);
    final live = !g.inert && !g.over && !viewer.readOnly && mySide != null;
    final myTurn = live && g.toMoveUserId == me;
    final opponent = me == g.firstUserId ? g.secondUserId : g.firstUserId;
    final offeredBy = g.drawOfferedBy;

    var status = viewer.status(g);
    final outcome = g.outcome;
    if (outcome != null) {
      final reason = outcome.reason == 'resigned'
          ? '${viewer.nameOf(g.winnerUserId == g.firstUserId ? g.secondUserId : g.firstUserId)} resigned'
          : _reasons[outcome.reason];
      if (reason != null) status = '$status · $reason';
    } else if (!g.inert) {
      final b = g.board;
      if (b is ChessBoard && b.inCheck) status = '$status · Check';
      if (offeredBy != null && offeredBy == me) {
        status = '$status · Draw offered';
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(g.type.title),
        actions: [
          if (live)
            PopupMenuButton<String>(
              tooltip: 'Game options',
              onSelected: (v) => switch (v) {
                'resign' => _confirm(
                  g,
                  title: 'Resign?',
                  body: '${viewer.nameOf(opponent)} wins this game.',
                  action: 'Resign',
                  move: const {'type': 'resign'},
                ),
                _ => _confirm(
                  g,
                  title: 'Offer a draw?',
                  body: '${viewer.nameOf(opponent)} can accept or decline.',
                  action: 'Offer draw',
                  move: const {'type': 'draw_offer'},
                ),
              },
              itemBuilder: (context) => [
                if (g.board.drawOffers && offeredBy == null)
                  const PopupMenuItem(value: 'draw', child: Text('Offer draw')),
                const PopupMenuItem(value: 'resign', child: Text('Resign')),
              ],
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (live && offeredBy != null && offeredBy != me)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.lg,
                  Space.sm,
                  Space.lg,
                  0,
                ),
                child: Material(
                  key: const Key('draw-offer'),
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(Radii.md),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Space.lg,
                      Space.xs,
                      Space.xs,
                      Space.xs,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${viewer.nameOf(offeredBy)} offers a draw',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSecondaryContainer,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () =>
                              _send(g, const {'type': 'draw_decline'}),
                          child: const Text('Decline'),
                        ),
                        TextButton(
                          onPressed: () =>
                              _send(g, const {'type': 'draw_accept'}),
                          child: const Text('Accept'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.lg,
                Space.md,
                Space.lg,
                0,
              ),
              child: Text(
                status,
                key: const Key('game-status'),
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: myTurn ? theme.colorScheme.tertiary : null,
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(Space.lg),
                child: LayoutBuilder(
                  builder: (context, box) {
                    final side = math.min(box.maxWidth, box.maxHeight);
                    return Center(
                      child: SizedBox.square(
                        dimension: side,
                        child: BoardView(
                          board: g.board,
                          mySide: mySide,
                          enabled: myTurn,
                          onPlay: (m) => _send(g, {'type': 'play', ...m}),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
