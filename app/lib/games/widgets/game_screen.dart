import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/db/chat_db.dart';
import '../../chat/providers.dart';
import '../../theme/motion.dart';
import '../../theme/tokens.dart';
import '../checkers.dart';
import '../chess_board.dart';
import '../game_state.dart';
import '../go_fish.dart';
import '../landlord/landlord.dart';
import '../providers.dart';
import '../rules.dart';
import '../war.dart';
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

  /// The first letter of [userId]'s display name (also for me), or empty.
  String initialOf(String userId) {
    final name = users[userId]?.name.trim() ?? '';
    return name.isEmpty ? '' : name.characters.first.toUpperCase();
  }

  /// `Your turn` (in checkers with a capture due, `Your turn: you have to
  /// jump`), `Mom's turn`, `You won`, `Mom won`, `Draw`,
  /// `Game not started`, `Game paused` for an unfinished game in a
  /// read-only chat, or `Update FamChat to keep playing` when out of sync.
  String status(GameState g) {
    if (g.inert) return 'Game not started';
    final outcome = g.outcome;
    if (outcome != null) {
      final winner = g.winnerUserId;
      if (winner == null) return 'Draw';
      return winner == me ? 'You won' : '${nameOf(winner)} won';
    }
    if (readOnly) return 'Game paused';
    if (g.outOfSync) return 'Update FamChat to keep playing';
    final next = g.toMoveUserId!;
    if (next != me) return "${nameOf(next)}'s turn";
    final b = g.board;
    return b is CheckersBoard && b.mustJump
        ? 'Your turn: you have to jump'
        : 'Your turn';
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

/// Opens game [gameId]'s board as an overlay over the app, on every window
/// size: what's behind is blurred and dimmed, and the board sits on a centred
/// panel (at most 560 wide). Tapping outside the panel, back or the panel's
/// close button closes it.
Future<void> openGame(BuildContext context, String chatId, String gameId) {
  final theme = Theme.of(context);
  final dark = theme.brightness == Brightness.dark;
  return Navigator.of(context, rootNavigator: true).push<void>(
    RawDialogRoute<void>(
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: theme.colorScheme.scrim.withValues(
        alpha: dark ? 0.5 : 0.28,
      ),
      transitionDuration: Motion.of(context, Motion.medium),
      pageBuilder: (context, _, _) => _GameOverlay(
        child: GameScreen(chatId: chatId, gameId: gameId),
      ),
      transitionBuilder: _overlayTransition,
    ),
  );
}

/// How much the app behind the board overlay is blurred.
const overlayBlurSigma = 14.0;

/// Blurs what's behind as the panel fades, rises and grows in. With reduced
/// motion the route has no duration, so it simply appears.
Widget _overlayTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  final t = CurvedAnimation(
    parent: animation,
    curve: Motion.enter,
    reverseCurve: Motion.exit,
  );
  return Stack(
    fit: StackFit.expand,
    children: [
      // Never hit: taps outside the panel reach the route's barrier below.
      IgnorePointer(
        child: AnimatedBuilder(
          animation: t,
          builder: (context, _) {
            final sigma = overlayBlurSigma * t.value;
            return BackdropFilter(
              key: const Key('game-overlay-blur'),
              filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
              child: const SizedBox.expand(),
            );
          },
        ),
      ),
      FadeTransition(
        opacity: t,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, 0.03),
            end: Offset.zero,
          ).animate(t),
          child: ScaleTransition(
            scale: Tween(begin: 0.95, end: 1.0).animate(t),
            child: child,
          ),
        ),
      ),
    ],
  );
}

/// Centres the board panel in the safe area, with a small side margin on
/// phones so the board gets most of the width. Only the panel takes taps.
class _GameOverlay extends StatelessWidget {
  const _GameOverlay({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.sizeOf(context).width < 600;
    return SafeArea(
      child: Center(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: phone ? Space.xs : Space.xl,
            vertical: phone ? Space.md : Space.xl,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560, maxHeight: 760),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Whether [g] offers Rematch: it's over, mine, the chat is writable and it is
/// the chat's newest game of its kind (long or quick) that started (inert
/// ones never did).
bool canRematch(List<GameState> games, GameState g, GameViewer viewer) {
  final me = viewer.me;
  final mine = g.firstUserId == me || g.secondUserId == me;
  final newest = games.lastWhere(
    (x) => !x.inert && x.type.long == g.type.long,
    orElse: () => g,
  );
  return g.over && !viewer.readOnly && mine && newest.id == g.id;
}

/// Starts a new game of [g]'s kind where whoever went second goes first, and
/// returns its id. If a game is already running (the other player's rematch
/// got there first), returns that one's instead. Null when offline.
Future<String?> startRematch(WidgetRef ref, String chatId, GameState g) async {
  final sync = ref.read(chatSyncProvider);
  if (sync == null) return null;
  final active = activeGame(ref.read(gamesProvider(chatId)), long: g.type.long);
  if (active != null) return active.id;
  final b = g.board;
  return sync.startGame(
    chatId,
    g.type,
    first: g.secondUserId,
    optionalJumps: b is CheckersBoard && b.optionalJumps,
  );
}

/// The panel's subtitle: who it's with, and a house rule in play.
String? _subtitle(String? who, Board b) {
  final rule = b is CheckersBoard && b.optionalJumps ? 'jumps optional' : null;
  if (rule == null) return who;
  return who == null ? 'Jumps optional' : '$who · $rule';
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

/// The final score of a game won or drawn on points, winner's first ("32–28").
String? _finalScore(Board b, Outcome o) {
  final s = boardScore(b);
  if (s == null) return null;
  final (a, c) = o.winner == Side.second ? (s.$2, s.$1) : s;
  return '$a–$c';
}

/// Where the board sits in the panel: a square as wide as the panel (or less
/// when the window is short), or, with [fill], all the room the panel has.
Widget _boardSlot({
  required bool fill,
  required bool phone,
  required Widget child,
}) {
  if (fill) {
    return Expanded(
      child: Padding(
        padding: EdgeInsets.all(phone ? Space.xs : Space.lg),
        child: child,
      ),
    );
  }
  return Flexible(
    child: Padding(
      padding: const EdgeInsets.all(Space.lg),
      child: Align(
        heightFactor: 1,
        child: AspectRatio(aspectRatio: 1, child: child),
      ),
    ),
  );
}

/// A game's board panel, live: plays, resignation, draw offers and Rematch.
/// [openGame] shows it over the conversation.
class GameScreen extends ConsumerStatefulWidget {
  const GameScreen({super.key, required this.chatId, required this.gameId});

  final String chatId, gameId;

  @override
  ConsumerState<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends ConsumerState<GameScreen> {
  /// The game shown: [GameScreen.gameId] until the user opens the running
  /// game from an inert one, or starts a rematch.
  late String _gameId = widget.gameId;

  /// A draw answer, resignation, draw offer or rematch is being confirmed or
  /// sent.
  var _busy = false;

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

  /// Runs [f] unless another action is running, disabling the action buttons
  /// meanwhile so a double tap sends one move.
  Future<void> _guard(Future<void> Function() f) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await f();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Answers a draw offer.
  Future<void> _answer(GameState g, String type) => _guard(() async {
    await ref.read(chatSyncProvider)?.sendMove(
      widget.chatId,
      g.id,
      g.type,
      g.ply,
      {'type': type},
    );
  });

  /// Starts a rematch (or switches to the game already running) in place.
  Future<void> _rematch(GameState g) => _guard(() async {
    final id = await startRematch(ref, widget.chatId, g);
    if (id != null && mounted) setState(() => _gameId = id);
  });

  Future<void> _confirm(
    GameState g, {
    required String title,
    required String body,
    required String action,
    required Map<String, Object?> move,
  }) => _guard(() async {
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
    await ref
        .read(chatSyncProvider)
        ?.sendMove(widget.chatId, now.id, now.type, now.ply, move);
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final games = ref.watch(gamesProvider(widget.chatId));
    final g = games.where((x) => x.id == _gameId).firstOrNull;
    final viewer = watchGameViewer(ref, widget.chatId);
    if (g == null) {
      // Loaded but missing: the game row failed or isn't a game.
      final loaded =
          ref.watch(chatProvider(widget.chatId)).hasValue &&
          ref.watch(messagesProvider(widget.chatId)).hasValue &&
          ref.watch(membersProvider(widget.chatId)).hasValue;
      return _Panel(
        title: 'Game',
        children: [
          SizedBox(
            height: 160,
            child: Center(
              child: loaded
                  ? Text(
                      "This game isn't available",
                      key: const Key('game-unavailable'),
                      style: theme.textTheme.bodyLarge,
                    )
                  : const SizedBox.square(
                      dimension: 32,
                      child: CircularProgressIndicator(),
                    ),
            ),
          ),
        ],
      );
    }
    final running = g.inert ? activeGame(games, long: g.type.long) : null;
    final me = viewer.me;
    final mySide = me == null ? null : g.sideOf(me);
    final live = !g.inert && !g.over && !viewer.readOnly && mySide != null;
    final myTurn = live && g.toMoveUserId == me;
    final opponent = me == g.firstUserId ? g.secondUserId : g.firstUserId;
    final offeredBy = g.drawOfferedBy;
    final behind = live && g.behindUserId != me ? g.behindUserId : null;

    var status = viewer.status(g);
    final outcome = g.outcome;
    if (outcome != null) {
      final reason = outcome.reason == 'resigned'
          ? '${viewer.nameOf(g.winnerUserId == g.firstUserId ? g.secondUserId : g.firstUserId)} resigned'
          : outcome.reason == 'bankrupt'
          ? '${viewer.nameOf(g.winnerUserId == g.firstUserId ? g.secondUserId : g.firstUserId)} went bankrupt'
          : outcome.reason == 'discs' ||
                outcome.reason == 'boxes' ||
                outcome.reason == 'books' ||
                outcome.reason == 'cards'
          ? _finalScore(g.board, outcome)
          : _reasons[outcome.reason];
      if (reason != null) status = '$status · $reason';
    } else if (!g.inert) {
      final b = g.board;
      if (b is ChessBoard && b.inCheck) status = '$status · Check';
      if (offeredBy != null && offeredBy == me) {
        status = '$status · Draw offered';
      }
    }

    return _Panel(
      title: g.type.title,
      subtitle: _subtitle(
        mySide == null ? null : 'with ${viewer.nameOf(opponent)}',
        g.board,
      ),
      actions: [
        if (live)
          PopupMenuButton<String>(
            enabled: !_busy,
            tooltip: 'Game options',
            icon: const Icon(Icons.more_horiz_rounded),
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
      children: [
        if (live && offeredBy != null && offeredBy != me)
          _Banner(
            key: const Key('draw-offer'),
            text: '${viewer.nameOf(offeredBy)} offers a draw',
            actions: [
              TextButton(
                onPressed: _busy ? null : () => _answer(g, 'draw_decline'),
                child: const Text('Decline'),
              ),
              TextButton(
                onPressed: _busy ? null : () => _answer(g, 'draw_accept'),
                child: const Text('Accept'),
              ),
            ],
          ),
        if (live && g.outOfSync)
          _Banner(
            key: const Key('game-out-of-sync'),
            text: "This game is out of step with ${viewer.nameOf(opponent)}'s FamChat. Update FamChat on both devices, or close and reopen it, to keep playing.",
            actions: const [],
          )
        else if (behind != null)
          _Banner(
            key: const Key('game-behind'),
            text: "${viewer.nameOf(behind)}'s FamChat is out of date. Ask them to update it, or close and reopen it, so this game stays in step.",
            actions: const [],
          ),
        if (running != null)
          _Banner(
            key: const Key('game-running'),
            text: 'A game is already running',
            actions: [
              TextButton(
                onPressed: () => setState(() => _gameId = running.id),
                child: const Text('Open'),
              ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, 0),
          child: Text(
            status,
            key: const Key('game-status'),
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              color: myTurn ? theme.colorScheme.tertiary : null,
              fontWeight: myTurn ? FontWeight.w600 : null,
            ),
          ),
        ),
        // The board takes the panel's width, or less when the window is short.
        // Landlord's ring and the Go Fish table stretch to any shape, so they
        // fill the panel instead.
        _boardSlot(
          fill:
              g.board is LandlordBoard ||
              g.board is GoFishBoard ||
              g.board is WarBoard,
          phone: MediaQuery.sizeOf(context).width < 600,
          child: BoardView(
            board: g.board,
            mySide: mySide,
            enabled: myTurn,
            initials: (
              viewer.initialOf(g.firstUserId),
              viewer.initialOf(g.secondUserId),
            ),
            names: (
              viewer.nameOf(g.firstUserId),
              viewer.nameOf(g.secondUserId),
            ),
            onPlay: (m) => _send(g, {'type': 'play', ...m}),
          ),
        ),
        if (canRematch(games, g, viewer))
          Padding(
            padding: const EdgeInsets.only(bottom: Space.lg),
            child: Center(
              child: FilledButton.tonalIcon(
                key: const Key('game-rematch'),
                onPressed: _busy ? null : () => _rematch(g),
                icon: const Icon(Icons.replay_rounded),
                label: const Text('Rematch'),
              ),
            ),
          ),
      ],
    );
  }
}

/// The board overlay's card: a header with [title], [subtitle], [actions]
/// and a close button, then [children] in a column only as tall as needed.
class _Panel extends StatelessWidget {
  const _Panel({
    required this.title,
    this.subtitle,
    this.actions = const [],
    required this.children,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    return Material(
      key: const Key('game-panel'),
      color: s.surfaceContainerLow,
      elevation: 12,
      shadowColor: s.shadow.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
        side: BorderSide(color: s.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.xl, Space.md, Space.sm, 0),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: s.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                ...actions,
                IconButton(
                  key: const Key('game-close'),
                  tooltip: 'Close',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.maybePop(context),
                ),
              ],
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}

/// A notice inside the panel with its own buttons (a draw offer, a running
/// game).
class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.text, required this.actions});

  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, 0),
      child: Material(
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
                  text,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
              ...actions,
            ],
          ),
        ),
      ),
    );
  }
}
