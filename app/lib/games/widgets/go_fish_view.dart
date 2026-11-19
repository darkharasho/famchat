import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../go_fish.dart';
import '../rules.dart';

const _words = {1: 'Ace', 11: 'Jack', 12: 'Queen', 13: 'King'};
const _faces = {1: 'A', 11: 'J', 12: 'Q', 13: 'K'};
const _suits = ['♠', '♥', '♦', '♣'];

/// [rank] (1..13) in words: `Ace`, `2`…`10`, `Jack`, `Queen`, `King`; plural
/// `Aces`, `2s`…`10s`, `Jacks`, `Queens`, `Kings`.
String rankName(int rank, {bool plural = false}) =>
    '${_words[rank] ?? '$rank'}${plural ? 's' : ''}';

String _a(int rank) => rank == 1 || rank == 8 ? 'an' : 'a';

/// One ask as a log line seen by [viewer], with [names] (first, second) as
/// shown ("You" for the viewer): "Mom asked for 7s — you gave 2". A card
/// drawn on "Go fish" is named only to the asker, or to both if it matched.
String goFishLog(GoFishEvent e, Side viewer, (String, String) names) {
  String name(Side s) => s == Side.first ? names.$1 : names.$2;
  final asker = name(e.asker), other = name(e.asker.other);
  final you = asker == 'You';
  final b = StringBuffer(
    '$asker asked for ${rankName(e.rank, plural: true)} — ',
  );
  final drawn = e.drawn;
  if (e.given > 0) {
    b.write('${other == 'You' ? 'you' : other} gave ${e.given}');
  } else {
    b.write('Go fish');
    if (drawn != null && e.again) {
      final r = GoFishBoard.rankOf(drawn);
      b.write(
        '. $asker drew ${_a(r)} ${rankName(r)} and ${you ? 'go' : 'goes'} again',
      );
    } else if (drawn != null && e.asker == viewer) {
      final r = GoFishBoard.rankOf(drawn);
      b.write('. $asker drew ${_a(r)} ${rankName(r)}');
    }
  }
  for (final (holder, rank) in e.booked) {
    b.write('. ${name(holder)} made a book of ${rankName(rank, plural: true)}');
  }
  return b.toString();
}

/// The table's own colours (like a felt), the same in light and dark.
abstract final class _Pal {
  static const table = Color(0xFF13292F);
  static const water = Color(0xFF11535C);
  static const deep = Color(0xFF0B3D45);
  static const shallow = Color(0xFF1A7480);
  static const rim = Color(0xFF0F3A40);
  static const foam = Color(0xFFBFE9E4);
  static const paper = Color(0xFFF7F1E3);
  static const paperEdge = Color(0xFFC9BFA8);
  static const ink = Color(0xFF1D2A2C);
  static const red = Color(0xFFD2453B);
  static const coral = Color(0xFFFF8A5C);
  static const gold = Color(0xFFFFD27A);
  static const muted = Color(0xFF8FB3B0);
  static const text = Color(0xFFEAF4F2);
  static const strip = Color(0xFF0E2A2F);
  static const stripEdge = Color(0xFF1F4A50);
  static const them = Color(0xFF3F8FD8);
  static const backA = Color(0xFF1B6D75);
  static const backB = Color(0xFF15606A);
}

/// The asks in [now] that [before] hasn't seen, oldest first: up to the last
/// three, or none when the two boards aren't one game a few asks apart.
@visibleForTesting
List<GoFishEvent> goFishNewEvents(GoFishBoard before, GoFishBoard now) {
  final a = before.events, b = now.events;
  if (b.isEmpty) return const [];
  if (a.isEmpty) return b.length <= 3 ? b : const [];
  for (var k = 0; k <= 3 && k < b.length; k++) {
    if (_same(b[b.length - 1 - k], a.last)) return b.sublist(b.length - k);
  }
  return const [];
}

bool _same(GoFishEvent x, GoFishEvent y) =>
    identical(x, y) ||
    (x.asker == y.asker &&
        x.rank == y.rank &&
        x.given == y.given &&
        x.drawn == y.drawn &&
        x.again == y.again &&
        listEquals(x.booked, y.booked));

/// Where a cue starts or ends: a player's cards (my hand or the opponent's
/// fan) or the pond.
enum _Spot { mine, theirs, pond }

/// One timed piece of an ask played out: [at] ms from the start, for [len].
sealed class _Cue {
  const _Cue(this.at, this.len);
  final int at, len;
}

/// A speech bubble from [mine] (my hand) or the opponent's seat.
class _Bubble extends _Cue {
  const _Bubble(super.at, super.len, this.text, {required this.mine});
  final String text;
  final bool mine;
}

/// Big words over the pond: "Go fish!", "Lucky!", "Book of 7s!".
class _Splash extends _Cue {
  const _Splash(super.at, super.len, this.text, {this.gold = false});
  final String text;
  final bool gold;
}

class _Ripple extends _Cue {
  const _Ripple(super.at, super.len);
}

/// A card moving [from] → [to]: face up if [card] is known to me, turning
/// over on the way if [flip].
class _Flight extends _Cue {
  const _Flight(
    super.at,
    super.len,
    this.from,
    this.to, {
    this.card,
    this.flip = false,
  });
  final _Spot from, to;
  final int? card;
  final bool flip;
}

/// My rank group raised while I ask for it.
class _Lift extends _Cue {
  const _Lift(super.at, super.len, this.rank);
  final int rank;
}

/// How the new asks play out. The board shown stays the old one until
/// [swap], when the cards have landed; the script ends at [total].
class _Script {
  const _Script(this.cues, this.swap, this.total);

  static const none = _Script([], 0, 0);

  final List<_Cue> cues;
  final int swap, total;

  /// [events] (new since [before], ending at [after]) from [me]'s seat;
  /// [me] null is a spectator, who sees no faces.
  factory _Script.plan(
    List<GoFishEvent> events,
    GoFishBoard before,
    GoFishBoard after,
    Side? me,
  ) {
    final seat = me ?? Side.first;
    final cues = <_Cue>[];
    var t = 0, swap = 0;
    _Spot spot(Side s) => s == seat ? _Spot.mine : _Spot.theirs;
    for (final e in events) {
      final asker = e.asker, giver = e.asker.other;
      final mine = asker == seat;
      final r = e.rank;
      cues.add(
        _Bubble(t, 1000, 'Got any ${rankName(r, plural: true)}?', mine: mine),
      );
      final int land;
      if (e.given > 0) {
        cues.add(
          _Bubble(
            t + 900,
            800,
            e.given == 1 ? 'Here you go' : "Here's ${e.given}",
            mine: !mine,
          ),
        );
        final faces = me == null
            ? const <int?>[]
            : _givenFaces(e, before, after, me);
        final n = e.given.clamp(1, 3);
        for (var i = 0; i < n; i++) {
          cues.add(
            _Flight(
              t + 1300 + i * 160,
              700,
              spot(giver),
              spot(asker),
              card: i < faces.length ? faces[i] : null,
              flip: asker == me,
            ),
          );
        }
        land = t + 1300 + (n - 1) * 160 + 700;
      } else {
        cues
          ..add(_Bubble(t + 900, 700, 'Go fish!', mine: !mine))
          ..add(_Splash(t + 1300, 1200, 'Go fish!'))
          ..add(_Ripple(t + 1500, 1100))
          ..add(_Ripple(t + 1750, 1100))
          ..add(_Ripple(t + 2000, 1100));
        if (e.drawn != null) {
          cues.add(
            _Flight(
              t + 2000,
              700,
              _Spot.pond,
              spot(asker),
              card: asker == me || e.again ? e.drawn : null,
              flip: asker == me || e.again,
            ),
          );
          land = t + 2700;
        } else {
          land = t + 2400;
        }
      }
      if (mine && me != null) cues.add(_Lift(t, land - t, r));
      var end = land + 400;
      if (e.given == 0 && e.again) {
        cues.add(_Splash(land, 1100, 'Lucky!', gold: true));
        end = land + 1100;
      }
      for (final (_, rank) in e.booked) {
        cues.add(
          _Splash(
            end - 400,
            1100,
            'Book of ${rankName(rank, plural: true)}!',
            gold: true,
          ),
        );
        end += 700;
      }
      swap = land;
      t = end + 150;
    }
    return _Script(cues, swap, t);
  }

  /// The faces of the cards [e] handed over, as far as [me] can know them:
  /// cards I gave, or cards I got.
  static List<int?> _givenFaces(
    GoFishEvent e,
    GoFishBoard before,
    GoFishBoard after,
    Side me,
  ) {
    bool ofRank(int c) => GoFishBoard.rankOf(c) == e.rank;
    if (e.asker != me) return before.hand(me).where(ofRank).toList();
    final had = before.hand(me).where(ofRank).toSet();
    if (e.booked.contains((me, e.rank))) {
      return [
        for (var s = 0; s < 4; s++)
          if (!had.contains((e.rank - 1) * 4 + s)) (e.rank - 1) * 4 + s,
      ];
    }
    return after.hand(me).where((c) => ofRank(c) && !had.contains(c)).toList();
  }
}

/// Go Fish from [mySide]'s seat, on a teal table: the opponent's card backs
/// and books on top, the stock as a pond in the middle with the latest asks
/// under it (tap for them all), my books and my hand (grouped by rank; tap a
/// rank to ask for it) at the bottom. Each new ask plays out: a speech
/// bubble, the answer, the cards flying across or "Go fish!" splashing in the
/// pond. The opponent's cards and the stock are never drawn face up;
/// spectators and thumbnails see no faces.
class GoFishView extends StatefulWidget {
  const GoFishView({
    super.key,
    required this.board,
    required this.mySide,
    required this.onPlay,
    required this.interactive,
    required this.thumbnail,
    this.names,
  });

  final GoFishBoard board;
  final Side? mySide;
  final void Function(Map<String, Object?> move) onPlay;
  final bool interactive, thumbnail;

  /// (first, second) players' display names, or null.
  final (String, String)? names;

  /// How many log lines show under the pond.
  static const logLines = 2;

  @override
  State<GoFishView> createState() => _GoFishViewState();
}

class _GoFishViewState extends State<GoFishView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(vsync: this);
  _Script _script = _Script.none;
  GoFishBoard? _before;
  final _stack = GlobalKey(),
      _theirs = GlobalKey(),
      _pond = GlobalKey(),
      _hand = GlobalKey();

  @override
  void didUpdateWidget(GoFishView old) {
    super.didUpdateWidget(old);
    if (identical(old.board, widget.board) || widget.thumbnail) return;
    final fresh = goFishNewEvents(old.board, widget.board);
    if (fresh.isEmpty || MediaQuery.of(context).disableAnimations) {
      _clock.stop();
      _script = _Script.none;
      _before = null;
      return;
    }
    _before = old.board;
    _script = _Script.plan(fresh, old.board, widget.board, widget.mySide);
    _clock
      ..duration = Duration(milliseconds: _script.total)
      ..forward(from: 0);
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  (String, String) get _names {
    final me = widget.mySide ?? Side.first;
    return widget.names ??
        (me == Side.first ? ('You', 'Opponent') : ('Opponent', 'You'));
  }

  void _showLog(BuildContext context, GoFishBoard board) {
    final me = widget.mySide ?? Side.first;
    final events = board.events.reversed.toList();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  'Moves',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Flexible(
                child: events.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(20),
                        child: Text('No moves yet'),
                      )
                    : ListView.builder(
                        key: const Key('gofish-log-list'),
                        shrinkWrap: true,
                        itemCount: events.length,
                        itemBuilder: (context, i) {
                          final e = events[i];
                          return ListTile(
                            dense: true,
                            leading: _Tag(
                              side: e.asker,
                              me: me,
                              names: _names,
                              size: 24,
                            ),
                            title: Text(goFishLog(e, me, _names)),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.thumbnail) return _Thumbnail(board: widget.board);
    return AnimatedBuilder(animation: _clock, builder: _table);
  }

  Widget _table(BuildContext context, Widget? _) {
    final playing = _clock.isAnimating && _before != null;
    final ms = playing ? _clock.value * _script.total : double.infinity;
    final board = playing && ms < _script.swap ? _before! : widget.board;
    double since(int start, int len) =>
        playing ? ((ms - start) / len).clamp(0.0, 1.0) : 1.0;

    final me = widget.mySide ?? Side.first;
    final them = me.other;
    final names = _names;
    String name(Side s) => s == Side.first ? names.$1 : names.$2;
    final canPlay =
        widget.interactive &&
        widget.mySide != null &&
        board.outcome == null &&
        board.toMove == widget.mySide &&
        !playing;

    // Cards and books that just arrived bounce in once the cards land.
    final before = _before;
    final arrived = before == null || !playing
        ? const <int>{}
        : widget.board.hand(me).toSet().difference(before.hand(me).toSet());
    final arrive = since(_script.swap, 500);
    int newBooks(Side s) => before == null || !playing
        ? 0
        : widget.board.books(s).length - before.books(s).length;
    final pop = since(_script.swap + 150, 650);
    int? lifted;
    var lift = 0.0;
    if (playing) {
      for (final c in _script.cues.whereType<_Lift>()) {
        if (ms >= c.at && ms < c.at + c.len) {
          lifted = c.rank;
          lift = (math.min(ms - c.at, c.at + c.len - ms) / 200).clamp(0.0, 1.0);
        }
      }
    }

    final log = board.events.length > GoFishView.logLines
        ? board.events.sublist(board.events.length - GoFishView.logLines)
        : board.events;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: _Pal.table,
        borderRadius: BorderRadius.circular(16),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final cardW = (box.maxWidth / 8.2).clamp(30.0, 52.0);
          return Stack(
            key: _stack,
            clipBehavior: Clip.hardEdge,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _PlayerRow(
                      key: _theirs,
                      side: them,
                      me: me,
                      names: names,
                      count: board.hand(them).length,
                      books: board.books(them),
                      fresh: newBooks(them),
                      pop: pop,
                      cardW: cardW * 0.7,
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: _Pond(key: _pond, stock: board.stockCount),
                    ),
                    const SizedBox(height: 10),
                    _LogStrip(
                      events: log,
                      total: board.events.length,
                      me: me,
                      names: names,
                      onTap: () => _showLog(context, board),
                    ),
                    const SizedBox(height: 6),
                    _MyBooks(
                      label: name(me) == 'You'
                          ? 'Your books'
                          : "${name(me)}'s books",
                      books: board.books(me),
                      fresh: newBooks(me),
                      pop: pop,
                    ),
                    const SizedBox(height: 4),
                    if (widget.mySide == null)
                      _PlayerRow(
                        side: me,
                        me: me,
                        names: names,
                        count: board.hand(me).length,
                        books: const [],
                        fresh: 0,
                        pop: 1,
                        cardW: cardW * 0.7,
                      )
                    else
                      _Hand(
                        key: _hand,
                        cards: board.hand(me),
                        cardW: cardW,
                        canPlay: canPlay,
                        lifted: lifted,
                        lift: lift,
                        arrived: arrived,
                        arrive: arrive,
                        onAsk: (rank) => widget.onPlay({'rank': rank}),
                      ),
                    SizedBox(
                      height: 22,
                      child: canPlay
                          ? const Center(
                              child: Text(
                                'Tap a rank to ask for it',
                                style: TextStyle(
                                  color: _Pal.muted,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            )
                          : null,
                    ),
                  ],
                ),
              ),
              if (playing)
                Positioned.fill(
                  child: IgnorePointer(child: _cues(ms, cardW, box.biggest)),
                ),
            ],
          );
        },
      ),
    );
  }

  /// The cues running at [ms], drawn over the table.
  Widget _cues(double ms, double cardW, Size size) {
    final stack = _stack.currentContext?.findRenderObject() as RenderBox?;
    if (stack == null || !stack.hasSize) return const SizedBox.shrink();
    Rect? rectOf(GlobalKey k) {
      final r = k.currentContext?.findRenderObject() as RenderBox?;
      if (r == null || !r.hasSize || !r.attached) return null;
      return r.localToGlobal(Offset.zero, ancestor: stack) & r.size;
    }

    final pond = rectOf(_pond);
    final theirs = rectOf(_theirs);
    final hand =
        rectOf(_hand) ??
        Rect.fromLTWH(0, size.height - cardW * 2.2, size.width, cardW * 1.4);
    Rect? at(_Spot s) => switch (s) {
      _Spot.mine => hand,
      _Spot.theirs => theirs,
      _Spot.pond => pond,
    };

    final out = <Widget>[];
    for (final c in _script.cues) {
      final local = ms - c.at;
      if (local < 0 || local > c.len) continue;
      final p = local / c.len;
      switch (c) {
        case _Bubble(:final text, :final mine):
          final anchor = mine ? hand : theirs;
          if (anchor == null) break;
          final scale = Curves.elasticOut
              .transform((local / 450).clamp(0.0, 1.0))
              .clamp(0.0, 1.3);
          final fade = ((c.len - local) / 250).clamp(0.0, 1.0);
          out.add(
            Positioned(
              left: mine ? 28 : null,
              right: mine ? null : 28,
              top: mine ? null : anchor.bottom + 4,
              bottom: mine ? size.height - anchor.top + 10 : null,
              child: Opacity(
                opacity: fade,
                child: Transform.scale(
                  scale: 0.3 + 0.7 * scale,
                  alignment: mine ? Alignment.bottomLeft : Alignment.topRight,
                  child: _SpeechBubble(text: text, mine: mine),
                ),
              ),
            ),
          );
        case _Splash(:final text, :final gold):
          if (pond == null) break;
          final grow = Curves.elasticOut.transform((p / 0.35).clamp(0.0, 1.0));
          final fade = p < 0.7 ? 1.0 : (1 - (p - 0.7) / 0.3);
          out.add(
            Positioned.fromRect(
              rect: pond,
              child: Align(
                alignment: Alignment(0, -0.1 - 0.4 * math.max(0, p - 0.6)),
                child: Opacity(
                  opacity: fade.clamp(0.0, 1.0),
                  child: Transform.rotate(
                    angle: (1 - grow) * -0.14,
                    child: Transform.scale(
                      scale: 0.4 + 0.6 * grow,
                      child: _SplashText(text: text, gold: gold),
                    ),
                  ),
                ),
              ),
            ),
          );
        case _Ripple():
          if (pond == null) break;
          final e = Curves.easeOut.transform(p);
          out.add(
            Positioned(
              left: pond.center.dx - (10 + 160 * e) / 2,
              top: pond.center.dy - (6 + 64 * e) / 2,
              child: Container(
                width: 10 + 160 * e,
                height: 6 + 64 * e,
                decoration: BoxDecoration(
                  shape: BoxShape.rectangle,
                  borderRadius: BorderRadius.all(
                    Radius.elliptical(5 + 80 * e, 3 + 32 * e),
                  ),
                  border: Border.all(
                    color: _Pal.foam.withValues(alpha: 0.9 * (1 - e)),
                    width: 2,
                  ),
                ),
              ),
            ),
          );
        case _Flight(:final from, :final to, :final card, :final flip):
          final a = at(from), b = at(to);
          if (a == null || b == null) break;
          final e = Curves.easeInOutCubic.transform(p);
          final centre = Offset.lerp(a.center, b.center, e)!;
          final turn = flip
              ? math.pi *
                    (1 -
                        Curves.easeInOut.transform(
                          ((p - 0.3) / 0.6).clamp(0.0, 1.0),
                        ))
              : 0.0;
          final face = card != null && turn < math.pi / 2;
          out.add(
            Positioned(
              left: centre.dx - cardW / 2,
              top: centre.dy - cardW * 0.7,
              child: Transform.rotate(
                angle: -0.25 * (1 - e),
                child: Transform.scale(
                  scale: 0.8 + 0.2 * e,
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, 0.001)
                      ..rotateY(turn),
                    child: face
                        ? _CardFace(card: card, width: cardW, lifted: true)
                        : _CardBack(width: cardW, lifted: true),
                  ),
                ),
              ),
            ),
          );
        case _Lift():
          break;
      }
    }
    return Stack(clipBehavior: Clip.none, children: out);
  }
}

class _SpeechBubble extends StatelessWidget {
  const _SpeechBubble({required this.text, required this.mine});

  final String text;
  final bool mine;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    decoration: BoxDecoration(
      color: _Pal.paper,
      borderRadius: BorderRadius.only(
        topLeft: const Radius.circular(18),
        topRight: Radius.circular(mine ? 18 : 4),
        bottomLeft: Radius.circular(mine ? 4 : 18),
        bottomRight: const Radius.circular(18),
      ),
      boxShadow: const [
        BoxShadow(
          color: Color(0x77000000),
          blurRadius: 18,
          offset: Offset(0, 6),
        ),
      ],
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: _Pal.ink,
        fontSize: 19,
        fontWeight: FontWeight.w900,
      ),
    ),
  );
}

class _SplashText extends StatelessWidget {
  const _SplashText({required this.text, required this.gold});

  final String text;
  final bool gold;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    style: TextStyle(
      fontSize: 44,
      fontWeight: FontWeight.w900,
      letterSpacing: 1,
      color: gold ? _Pal.gold : _Pal.foam,
      shadows: [
        Shadow(
          color: gold ? const Color(0xFF7A4B00) : const Color(0xFF0B3D45),
          offset: const Offset(0, 3),
        ),
        Shadow(
          color: (gold ? _Pal.gold : _Pal.foam).withValues(alpha: 0.6),
          blurRadius: 24,
        ),
      ],
    ),
  );
}

/// A player's initial in their colour: coral for me, blue for the other.
class _Tag extends StatelessWidget {
  const _Tag({
    required this.side,
    required this.me,
    required this.names,
    this.size = 18,
  });

  final Side side, me;
  final (String, String) names;
  final double size;

  @override
  Widget build(BuildContext context) {
    final name = side == Side.first ? names.$1 : names.$2;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: side == me ? _Pal.coral : _Pal.them,
      ),
      child: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.5,
          fontWeight: FontWeight.w900,
          height: 1,
        ),
      ),
    );
  }
}

/// A name, a fan of card backs with the count, and the books made.
class _PlayerRow extends StatelessWidget {
  const _PlayerRow({
    super.key,
    required this.side,
    required this.me,
    required this.names,
    required this.count,
    required this.books,
    required this.fresh,
    required this.pop,
    required this.cardW,
  });

  final Side side, me;
  final (String, String) names;
  final int count, fresh;
  final List<int> books;
  final double cardW, pop;

  @override
  Widget build(BuildContext context) {
    final shown = count.clamp(0, 9);
    final step = cardW * 0.34;
    final name = side == Side.first ? names.$1 : names.$2;
    return Row(
      children: [
        _Tag(side: side, me: me, names: names, size: 26),
        const SizedBox(width: 8),
        Text(
          name,
          style: const TextStyle(
            color: _Pal.text,
            fontSize: 15,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: shown == 0 ? 0 : cardW + (shown - 1) * step,
          height: cardW * 1.4 + 4,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (var i = 0; i < shown; i++)
                Positioned(
                  left: i * step,
                  top: 2,
                  child: Transform.rotate(
                    angle: (i - shown / 2) * 0.05,
                    child: _CardBack(width: cardW),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          count == 1 ? '1 card' : '$count cards',
          style: const TextStyle(
            color: _Pal.muted,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        const Spacer(),
        Flexible(
          child: _Chips(books: books, fresh: fresh, pop: pop, end: true),
        ),
      ],
    );
  }
}

/// Books as stacked rank chips; the last [fresh] pop in with [pop] (0..1).
class _Chips extends StatelessWidget {
  const _Chips({
    required this.books,
    required this.fresh,
    required this.pop,
    this.end = false,
  });

  final List<int> books;
  final int fresh;
  final double pop;
  final bool end;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    reverse: end,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < books.length; i++)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: _chip(books[i], i >= books.length - fresh),
          ),
      ],
    ),
  );

  Widget _chip(int rank, bool isNew) {
    final chip = Container(
      key: Key('book-$rank'),
      constraints: const BoxConstraints(minWidth: 26),
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: _Pal.paper,
        borderRadius: BorderRadius.circular(7),
        boxShadow: [
          const BoxShadow(color: _Pal.paperEdge, offset: Offset(2, 2)),
          const BoxShadow(color: Color(0xFFA99F88), offset: Offset(4, 4)),
          if (isNew && pop < 1)
            BoxShadow(
              color: _Pal.gold.withValues(alpha: 1 - pop),
              blurRadius: 16,
            ),
        ],
      ),
      child: Text(
        _faces[rank] ?? '$rank',
        style: const TextStyle(
          color: _Pal.ink,
          fontSize: 14,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
    if (!isNew || pop >= 1) return chip;
    final s = Curves.elasticOut.transform(pop);
    return Opacity(
      opacity: pop.clamp(0.0, 1.0),
      child: Transform.rotate(
        angle: (1 - s) * -0.2,
        child: Transform.scale(scale: 1.8 - 0.8 * s, child: chip),
      ),
    );
  }
}

class _MyBooks extends StatelessWidget {
  const _MyBooks({
    required this.label,
    required this.books,
    required this.fresh,
    required this.pop,
  });

  final String label;
  final List<int> books;
  final int fresh;
  final double pop;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 36,
    child: Row(
      children: [
        Text(
          books.isEmpty ? '$label: none yet' : label,
          style: const TextStyle(
            color: _Pal.muted,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: _Chips(books: books, fresh: fresh, pop: pop),
          ),
        ),
      ],
    ),
  );
}

/// The stock as a pond of floating card backs, fewer as it empties.
class _Pond extends StatelessWidget {
  const _Pond({super.key, required this.stock});

  final int stock;

  static const _spots = [
    (0.22, 0.30, -0.42),
    (0.40, 0.22, 0.21),
    (0.60, 0.34, -0.14),
    (0.32, 0.52, 0.52),
    (0.52, 0.56, -0.52),
    (0.70, 0.48, 0.31),
    (0.46, 0.40, 0.07),
    (0.26, 0.70, -0.21),
    (0.62, 0.72, 0.38),
  ];

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      final cardW = (math.min(w, h * 1.2) / 9).clamp(18.0, 40.0);
      final floating = (stock / 3).ceil().clamp(0, _spots.length);
      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.only(
            topLeft: Radius.elliptical(w * 0.5, h * 0.4),
            topRight: Radius.elliptical(w * 0.46, h * 0.44),
            bottomRight: Radius.elliptical(w * 0.48, h * 0.56),
            bottomLeft: Radius.elliptical(w * 0.52, h * 0.6),
          ),
          border: Border.all(color: _Pal.rim, width: 6),
          gradient: const RadialGradient(
            center: Alignment(-0.2, -0.3),
            radius: 0.9,
            colors: [_Pal.shallow, _Pal.water, _Pal.deep],
            stops: [0, 0.45, 1],
          ),
          boxShadow: const [
            BoxShadow(color: Color(0xFF1F5960), spreadRadius: 1),
          ],
        ),
        child: Stack(
          children: [
            for (final (x, y, r) in _spots.take(floating))
              Positioned(
                left: x * w - cardW / 2,
                top: y * h - cardW * 0.7,
                child: Transform.rotate(
                  angle: r,
                  child: Opacity(opacity: 0.92, child: _CardBack(width: cardW)),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: h * 0.08,
              child: Text(
                stock == 0 ? 'The pond is empty' : '$stock in the pond',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _Pal.foam.withValues(alpha: 0.85),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// The last asks, newest on top; tapping opens every move.
class _LogStrip extends StatelessWidget {
  const _LogStrip({
    required this.events,
    required this.total,
    required this.me,
    required this.names,
    required this.onTap,
  });

  final List<GoFishEvent> events;
  final int total;
  final Side me;
  final (String, String) names;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final lines = events.reversed.toList();
    return Semantics(
      button: true,
      label: 'All moves',
      child: GestureDetector(
        key: const Key('gofish-log'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: _Pal.strip,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _Pal.stripEdge),
          ),
          child: lines.isEmpty
              ? const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'No moves yet',
                    style: TextStyle(
                      color: _Pal.muted,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                )
              : Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          for (var i = 0; i < lines.length; i++)
                            Row(
                              children: [
                                _Tag(
                                  side: lines[i].asker,
                                  me: me,
                                  names: names,
                                ),
                                const SizedBox(width: 7),
                                Expanded(
                                  child: Text(
                                    goFishLog(lines[i], me, names),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: i == 0 ? _Pal.text : _Pal.muted,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                    if (total > lines.length) ...[
                      const SizedBox(width: 8),
                      Text(
                        'All $total',
                        style: const TextStyle(
                          color: _Pal.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

/// My cards grouped by rank, each group a tap target `rank-<r>` (scrolls
/// sideways when wide). [lifted]'s group rises by [lift] (0..1) while I ask
/// for it; [arrived] cards drop in with [arrive] (0..1).
class _Hand extends StatelessWidget {
  const _Hand({
    super.key,
    required this.cards,
    required this.cardW,
    required this.canPlay,
    required this.onAsk,
    this.lifted,
    this.lift = 0,
    this.arrived = const {},
    this.arrive = 1,
  });

  final List<int> cards;
  final double cardW, lift, arrive;
  final bool canPlay;
  final int? lifted;
  final Set<int> arrived;
  final void Function(int rank) onAsk;

  static const _rise = 16.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final groups = <int, List<int>>{};
      for (final c in cards) {
        (groups[GoFishBoard.rankOf(c)] ??= []).add(c);
      }
      // Shrink the cards so the whole hand fits, down to a readable size;
      // past that it scrolls.
      final g = groups.length, extra = cards.length - g;
      final fit = (box.maxWidth - 8 * g) / (g + 0.35 * extra);
      final w = g == 0 ? cardW : fit.clamp(26.0, cardW);
      return _row(groups, w);
    },
  );

  Widget _row(Map<int, List<int>> groups, double cardW) {
    final overlap = cardW * 0.35;
    final drop = 1 - Curves.elasticOut.transform(arrive);
    return SizedBox(
      height: cardW * 1.4 + _rise + 4,
      child: Center(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final MapEntry(key: rank, value: group) in groups.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Semantics(
                    button: canPlay,
                    label: 'Ask for ${rankName(rank, plural: true)}',
                    child: GestureDetector(
                      key: Key('rank-$rank'),
                      behavior: HitTestBehavior.opaque,
                      onTap: canPlay ? () => onAsk(rank) : null,
                      child: Transform.translate(
                        offset: Offset(0, rank == lifted ? -_rise * lift : 0),
                        child: SizedBox(
                          width: cardW + (group.length - 1) * overlap,
                          height: cardW * 1.4,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              for (var i = 0; i < group.length; i++)
                                Positioned(
                                  left: i * overlap,
                                  child: Transform.translate(
                                    offset: Offset(
                                      0,
                                      arrived.contains(group[i])
                                          ? -30 * drop
                                          : 0,
                                    ),
                                    child: _CardFace(
                                      key: Key('card-${group[i]}'),
                                      card: group[i],
                                      width: cardW,
                                      asking: rank == lifted && lift > 0,
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
            ],
          ),
        ),
      ),
    );
  }
}

class _CardFace extends StatelessWidget {
  const _CardFace({
    super.key,
    required this.card,
    required this.width,
    this.asking = false,
    this.lifted = false,
  });

  final int card;
  final double width;
  final bool asking, lifted;

  @override
  Widget build(BuildContext context) {
    final suit = GoFishBoard.suitOf(card);
    final red = suit == 1 || suit == 2;
    final rank = GoFishBoard.rankOf(card);
    return Container(
      width: width,
      height: width * 1.4,
      padding: EdgeInsets.all(width * 0.09),
      decoration: BoxDecoration(
        color: _Pal.paper,
        borderRadius: BorderRadius.circular(width * 0.14),
        boxShadow: [
          if (asking) const BoxShadow(color: _Pal.coral, spreadRadius: 2),
          BoxShadow(
            color: const Color(0x77000000),
            blurRadius: lifted || asking ? 14 : 6,
            offset: Offset(0, lifted || asking ? 6 : 3),
          ),
        ],
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(
          color: red ? _Pal.red : _Pal.ink,
          height: 1,
          fontWeight: FontWeight.w900,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _faces[rank] ?? '$rank',
              style: TextStyle(fontSize: width * 0.34),
            ),
            Expanded(
              child: Center(
                child: Text(
                  _suits[suit],
                  style: TextStyle(
                    fontSize: width * 0.45,
                    fontFamily: 'NotoSansSymbols2',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A teal card back: diagonal stripes, a cream edge and an oval.
class _CardBack extends StatelessWidget {
  const _CardBack({required this.width, this.lifted = false});

  final double width;
  final bool lifted;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: width * 1.4,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(width * 0.12),
      border: Border.all(color: _Pal.paper, width: 1.5),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment(-1 + 16 / width, -1 + 16 / (width * 1.4)),
        colors: const [_Pal.backA, _Pal.backA, _Pal.backB, _Pal.backB],
        stops: const [0, 0.5, 0.5, 1],
        tileMode: TileMode.repeated,
      ),
      boxShadow: [
        BoxShadow(
          color: const Color(0x66000000),
          blurRadius: lifted ? 12 : 4,
          offset: Offset(0, lifted ? 5 : 2),
        ),
      ],
    ),
    child: Center(
      child: Container(
        width: width * 0.55,
        height: width * 0.9,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.all(
            Radius.elliptical(width * 0.28, width * 0.45),
          ),
          border: Border.all(color: _Pal.foam.withValues(alpha: 0.55)),
        ),
      ),
    ),
  );
}

/// The card's picture: counts only, never faces (the chat may be on a shared
/// screen).
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.board});

  final GoFishBoard board;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (a, b) = board.scores;
    return LayoutBuilder(
      builder: (context, box) {
        final w = (box.maxHeight / 2.2).clamp(16.0, 60.0);
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _CardBack(width: w),
                const SizedBox(height: 4),
                Text(
                  '${board.stockCount} left',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('$a–$b', style: theme.textTheme.titleLarge),
                Text('books', style: theme.textTheme.bodySmall),
              ],
            ),
          ],
        );
      },
    );
  }
}
