import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../rules.dart';
import '../war.dart';
import 'board_parts.dart';

/// The War table's own colours: a wine-red felt, brass, cream cards and navy
/// backs.
abstract final class _W {
  static const table = Color(0xFF3B1A20);
  static const deep = Color(0xFF240F13);
  static const rim = Color(0xFF5C2A31);
  static const paper = Color(0xFFF7F1E3);
  static const ink = Color(0xFF1F1A1C);
  static const red = Color(0xFFC8323A);
  static const brass = Color(0xFFE6B65E);
  static const muted = Color(0xFFD8B4AE);
  static const backA = Color(0xFF1D2944);
  static const backB = Color(0xFF2B3C63);
}

const _faces = {1: 'A', 11: 'J', 12: 'Q', 13: 'K'};
const _suits = ['♠', '♥', '♦', '♣'];

/// [card] as "K♠".
String warCardName(int card) =>
    '${_faces[WarBoard.rankOf(card)] ?? WarBoard.rankOf(card)}'
    '${_suits[WarBoard.suitOf(card)]}';

/// One line about [b]: "Your K♠ beat Mom's 7♥ · +2", with "War! " in front
/// when there was one. [names] are (first, second); "You" reads "Your".
String warLog(WarBattle b, (String, String) names) {
  String whose(Side s) {
    final n = s == Side.first ? names.$1 : names.$2;
    return n == 'You' ? 'Your' : "$n's";
  }

  final (x, y) = b.rounds.last;
  final war = b.war ? 'War! ' : '';
  final w = b.winner;
  if (w == null) return '${war}Out of cards: each took theirs back';
  final (mine, theirs) = w == Side.first ? (x, y) : (y, x);
  return '$war${whose(w)} ${warCardName(mine)} beat '
      '${whose(w.other).replaceFirst('Your', 'your')} ${warCardName(theirs)}'
      ' · +${b.pot}';
}

/// War: each player's deck on their side of a felt table (mine at the
/// bottom), cards won in a pile beside it. On my turn I tap my deck to flip:
/// both top cards fly to the middle and turn over; a tie stamps "WAR!", three
/// cards each slide in face down and the next pair flips; then the pot
/// sweeps to the winner's pile. The last battle stays written in the middle.
class WarView extends StatefulWidget {
  const WarView({
    super.key,
    required this.board,
    required this.mySide,
    required this.onPlay,
    required this.interactive,
    required this.thumbnail,
    this.names,
  });

  final WarBoard board;
  final Side? mySide;
  final void Function(Map<String, Object?> move) onPlay;
  final bool interactive, thumbnail;
  final (String, String)? names;

  @override
  State<WarView> createState() => _WarViewState();
}

class _WarViewState extends MoveMotionState<WarView> {
  /// The battle playing out, the board before it, and its timeline: each
  /// round's (start, end) in ms, then the sweep's start.
  WarBattle? _battle;
  WarBoard? _before;
  List<(int, int)> _rounds = const [];
  int _sweep = 0, _total = 1;

  static const _flyMs = 320, _turnMs = 220, _gapMs = 320, _warMs = 880;
  static const _holdMs = 480, _sweepMs = 460;

  @override
  void didUpdateWidget(WarView old) {
    super.didUpdateWidget(old);
    final a = old.board, b = widget.board;
    if (widget.thumbnail || b.battles.isEmpty || b.toMove == a.toMove) return;
    final battle = b.battles.last;
    if (b.flips != a.flips + 1) return;
    final rounds = <(int, int)>[(0, _flyMs + _turnMs)];
    for (var r = 1; r < battle.rounds.length; r++) {
      final s = rounds.last.$2 + _gapMs;
      rounds.add((s, s + _warMs));
    }
    _battle = battle;
    _before = a;
    _rounds = rounds;
    _sweep = rounds.last.$2 + _holdMs;
    _total = _sweep + _sweepMs;
    playMove(_total);
  }

  double _ms(int from, int to, [Curve c = Curves.easeInOut]) =>
      phase(from / _total, to / _total, c);

  String _name(Side s) {
    final n = widget.names;
    if (n == null) return s == Side.first ? 'First' : 'Second';
    final v = s == Side.first ? n.$1 : n.$2;
    return v.isEmpty ? (s == Side.first ? 'First' : 'Second') : v;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: clock,
    builder: (context, _) =>
        LayoutBuilder(builder: (context, box) => _table(context, box.biggest)),
  );

  Widget _table(BuildContext context, Size size) {
    final board = widget.board;
    final me = widget.mySide ?? Side.first, them = me.other;
    final thumb = widget.thumbnail;
    final wd = size.width, ht = size.height;
    final ch = math.min(ht * (thumb ? 0.42 : 0.27), wd * 0.2 * 1.4);
    final cw = ch / 1.4;
    final animating = moving && _battle != null;
    final battle = animating ? _battle! : null;
    final shown = animating ? _before! : board;
    final sweeping =
        animating && clock.value * _total >= _sweep + _sweepMs * 0.6;

    Offset deckAt(Side s) => Offset(wd * 0.15, s == me ? ht * 0.78 : ht * 0.22);
    Offset wonAt(Side s) => Offset(wd * 0.85, s == me ? ht * 0.78 : ht * 0.22);
    // Battle columns: one per round, centred.
    final n = battle?.rounds.length ?? 1;
    final step = n == 1 ? 0.0 : math.min(cw * 1.6, wd * 0.56 / (n - 1));
    Offset slot(Side s, int r) => Offset(
      wd * 0.5 + (r - (n - 1) / 2) * step,
      ht * 0.5 + (s == me ? 1 : -1) * ch * 0.56,
    );

    final children = <Widget>[];
    void card(Offset c, Widget w, {double scale = 1, double turn = 1}) {
      children.add(
        Positioned(
          left: c.dx - cw / 2,
          top: c.dy - ch / 2,
          width: cw,
          height: ch,
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.diagonal3Values(turn * scale, scale, 1),
            child: w,
          ),
        ),
      );
    }

    // Decks and won piles.
    for (final s in [them, me]) {
      // A deck that runs out mid-battle takes its pile (whole deck).
      final left = battle == null ? shown.deck(s).length : _left(shown, s);
      children.add(
        _pile(
          at: deckAt(s),
          cw: cw,
          ch: ch,
          count: left,
          key: Key('war-deck-${s == me ? 'me' : 'them'}'),
          label: thumb ? null : '${_name(s)} · $left',
          glow: s == me && _canFlip && !animating,
          onTap: s == me && _canFlip && !animating
              ? () => widget.onPlay(const {'flip': true})
              : null,
        ),
      );
      final won = sweeping
          ? board.pile(s).length
          : battle != null && _reshuffled(shown, s)
          ? 0
          : shown.pile(s).length;
      children.add(
        _pile(
          at: wonAt(s),
          cw: cw,
          ch: ch,
          count: won,
          key: Key('war-won-${s == me ? 'me' : 'them'}'),
          label: thumb ? null : 'Won $won',
          bump: sweeping && battle?.winner == s,
        ),
      );
    }

    if (battle != null) {
      final t = clock.value * _total;
      final sweep = _ms(_sweep, _sweep + _sweepMs, Curves.easeInCubic);
      for (var r = 0; r < battle.rounds.length; r++) {
        final (s0, _) = _rounds[r];
        if (t < s0) break;
        final (x, y) = battle.rounds[r];
        // Face-down cards first (before war r), fanned behind the slot.
        if (r > 0) {
          final downs = battle.downs[r - 1];
          for (var k = 0; k < downs; k++) {
            for (final s in [them, me]) {
              final f = _ms(s0 + k * 70, s0 + k * 70 + 300, Curves.easeOut);
              final rest = slot(s, r) + Offset(-cw * 0.09 * (k + 1), 0);
              final from = deckAt(s);
              final to = Offset.lerp(rest, _sweepTo(battle, s, wonAt), sweep)!;
              card(
                Offset.lerp(from, sweep > 0 ? to : rest, sweep > 0 ? 1 : f)!,
                _CardBack(width: cw),
              );
            }
          }
        }
        final fly0 = r == 0 ? s0 : s0 + 350;
        final turn0 = fly0 + _flyMs;
        for (final s in [them, me]) {
          final c = s == Side.first ? x : y;
          final f = _ms(fly0, turn0, Curves.easeOutCubic);
          if (t < fly0) continue;
          final turnT = _ms(turn0, turn0 + _turnMs);
          final rest = slot(s, r);
          final win =
              r == battle.rounds.length - 1 &&
              battle.winner == s &&
              t >= turn0 + _turnMs;
          final at = sweep > 0
              ? Offset.lerp(rest, _sweepTo(battle, s, wonAt), sweep)!
              : Offset.lerp(deckAt(s), rest, f)!;
          card(
            at,
            turnT < 0.5
                ? _CardBack(width: cw)
                : _CardFace(card: c, width: cw, glow: win && sweep == 0),
            scale: 1 + 0.08 * math.sin(math.pi * f) - 0.25 * sweep,
            turn: math.max(0.04, (math.cos(math.pi * turnT)).abs()),
          );
        }
        if (r > 0) {
          // "WAR!" stamps on as the war begins.
          final w = _ms(s0 - _gapMs, s0 + 420, Curves.easeOutBack);
          final fade = 1 - _ms(s0 + 500, s0 + 760);
          if (w > 0 && fade > 0) {
            children.add(
              Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: Opacity(
                      opacity: fade.clamp(0.0, 1.0),
                      child: Transform.scale(
                        scale: 0.4 + 0.8 * w,
                        child: _Stamp(size: ch * 0.42),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
        }
      }
    } else if (!thumb) {
      children.add(
        Positioned(
          left: wd * 0.27,
          right: wd * 0.27,
          top: ht * 0.5 - 40,
          height: 80,
          child: Center(child: _caption(context, ch)),
        ),
      );
    } else if (board.battles.isNotEmpty) {
      final (x, y) = board.battles.last.rounds.last;
      card(
        slot(them, 0),
        _CardFace(card: them == Side.first ? x : y, width: cw),
      );
      card(slot(me, 0), _CardFace(card: me == Side.first ? x : y, width: cw));
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(thumb ? 6 : 18),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(radius: 1.1, colors: [_W.table, _W.deep]),
        ),
        child: Stack(children: children),
      ),
    );
  }

  /// [s]'s deck so far in the battle playing out from [before].
  int _left(WarBoard before, Side s) {
    final gone = _gone(s);
    final deck = before.deck(s).length;
    if (gone <= deck) return deck - gone;
    return before.pile(s).length - (gone - deck);
  }

  /// Whether [s]'s pile has gone into their deck yet in the battle playing out.
  bool _reshuffled(WarBoard before, Side s) =>
      before.wholeDeck && _gone(s) > before.deck(s).length;

  /// Cards that have left [s]'s deck so far in the battle playing out.
  int _gone(Side s) {
    final b = _battle!;
    final t = clock.value * _total;
    var gone = 0;
    for (var r = 0; r < b.rounds.length; r++) {
      final (s0, _) = _rounds[r];
      if (t < s0) break;
      if (r > 0) gone += b.downs[r - 1];
      if (t >= (r == 0 ? s0 : s0 + 350)) gone++;
    }
    return gone;
  }

  Offset _sweepTo(WarBattle b, Side s, Offset Function(Side) wonAt) =>
      wonAt(b.winner ?? s);

  bool get _canFlip =>
      widget.interactive &&
      widget.board.outcome == null &&
      widget.board.toMove == widget.mySide;

  Widget _caption(BuildContext context, double ch) {
    final board = widget.board;
    final names = (_name(Side.first), _name(Side.second));
    final String text;
    if (board.battles.isEmpty) {
      text = _canFlip
          ? 'Tap your deck to flip. Higher card takes both.'
          : 'Higher card takes both. A tie means war.';
    } else {
      final line = warLog(board.battles.last, names);
      text = board.outcome == null && _canFlip ? '$line\nYour flip' : line;
    }
    return Text(
      text,
      key: const Key('war-caption'),
      textAlign: TextAlign.center,
      maxLines: 3,
      style: TextStyle(
        color: _W.muted,
        fontSize: (ch * 0.13).clamp(11.0, 15.0),
        fontWeight: FontWeight.w600,
        height: 1.35,
        // Suits from the bundled symbols font, never colour emoji.
        fontFamilyFallback: const ['NotoSansSymbols2'],
      ),
    );
  }

  Widget _pile({
    required Offset at,
    required double cw,
    required double ch,
    required int count,
    required Key key,
    String? label,
    bool glow = false,
    bool bump = false,
    VoidCallback? onTap,
  }) {
    final layers = math.min(count, 4);
    final pile = SizedBox(
      width: cw + 6,
      height: ch + 6,
      child: Stack(
        children: [
          if (count == 0)
            Positioned(
              left: 0,
              top: 0,
              width: cw,
              height: ch,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(cw * 0.12),
                  border: Border.all(color: _W.rim, width: 1.5),
                ),
              ),
            ),
          for (var i = 0; i < layers; i++)
            Positioned(
              left: (layers - 1 - i) * 1.5,
              top: (layers - 1 - i) * 1.5,
              width: cw,
              height: ch,
              child: _CardBack(width: cw, glow: glow && i == layers - 1),
            ),
        ],
      ),
    );
    return Positioned(
      left: at.dx - cw / 2,
      top: at.dy - ch / 2,
      child: Semantics(
        key: key,
        label: onTap != null ? 'Flip. ${label ?? ''}' : label,
        button: onTap != null,
        excludeSemantics: true,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TweenAnimationBuilder<double>(
                key: ValueKey(count),
                tween: Tween(begin: bump ? 0 : 1, end: 1),
                duration: const Duration(milliseconds: 360),
                builder: (context, t, child) => Transform.scale(
                  scale: 1 + 0.12 * math.sin(math.pi * t),
                  child: child,
                ),
                child: pile,
              ),
              if (label != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    label,
                    maxLines: 1,
                    style: TextStyle(
                      color: glow ? _W.brass : _W.muted,
                      fontSize: (ch * 0.12).clamp(10.0, 14.0),
                      fontWeight: FontWeight.w700,
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

/// "WAR!" in brass, stamped at an angle.
class _Stamp extends StatelessWidget {
  const _Stamp({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => Transform.rotate(
    angle: -0.12,
    child: Container(
      padding: EdgeInsets.symmetric(
        horizontal: size * 0.35,
        vertical: size * 0.08,
      ),
      decoration: BoxDecoration(
        color: _W.deep.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(size * 0.2),
        border: Border.all(color: _W.brass, width: 3),
        boxShadow: const [BoxShadow(color: Color(0x88000000), blurRadius: 16)],
      ),
      child: Text(
        'WAR!',
        style: TextStyle(
          color: _W.brass,
          fontSize: size,
          fontWeight: FontWeight.w900,
          letterSpacing: size * 0.06,
          height: 1,
        ),
      ),
    ),
  );
}

class _CardFace extends StatelessWidget {
  const _CardFace({required this.card, required this.width, this.glow = false});

  final int card;
  final double width;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final suit = WarBoard.suitOf(card);
    final red = suit == 1 || suit == 2;
    final rank = WarBoard.rankOf(card);
    return Container(
      key: Key('war-card-$card'),
      width: width,
      height: width * 1.4,
      padding: EdgeInsets.all(width * 0.09),
      decoration: BoxDecoration(
        color: _W.paper,
        borderRadius: BorderRadius.circular(width * 0.12),
        boxShadow: [
          if (glow)
            const BoxShadow(color: _W.brass, spreadRadius: 3, blurRadius: 10),
          const BoxShadow(
            color: Color(0x77000000),
            blurRadius: 6,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(
          color: red ? _W.red : _W.ink,
          height: 1,
          fontWeight: FontWeight.w900,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _faces[rank] ?? '$rank',
              style: TextStyle(fontSize: width * 0.3),
            ),
            Expanded(
              child: Center(
                child: Text(
                  _suits[suit],
                  style: TextStyle(
                    fontSize: width * 0.5,
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

class _CardBack extends StatelessWidget {
  const _CardBack({required this.width, this.glow = false});

  final double width;
  final bool glow;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: width * 1.4,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(width * 0.12),
      border: Border.all(
        color: glow ? _W.brass : _W.paper,
        width: glow ? 2.5 : 1.5,
      ),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment(-1 + 14 / width, -1 + 14 / (width * 1.4)),
        colors: const [_W.backA, _W.backA, _W.backB, _W.backB],
        stops: const [0, 0.5, 0.5, 1],
        tileMode: TileMode.repeated,
      ),
      boxShadow: [
        if (glow)
          BoxShadow(color: _W.brass.withValues(alpha: 0.6), blurRadius: 14),
        const BoxShadow(
          color: Color(0x66000000),
          blurRadius: 4,
          offset: Offset(0, 2),
        ),
      ],
    ),
    child: Center(
      child: Transform.rotate(
        angle: math.pi / 4,
        child: Container(
          width: width * 0.36,
          height: width * 0.36,
          decoration: BoxDecoration(
            border: Border.all(
              color: _W.brass.withValues(alpha: 0.7),
              width: 1.5,
            ),
          ),
        ),
      ),
    ),
  );
}
