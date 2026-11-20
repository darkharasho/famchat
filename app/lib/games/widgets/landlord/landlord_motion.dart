part of 'landlord_view.dart';

// Landlord's motion: the dice tumble, then the token hops space by space;
// cash counts to its new value with the change floating off; the deed is
// dealt onto the felt once the token arrives. Everything is skipped when the
// platform asks for reduced motion.

bool _still(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

/// The newest roll in [b]'s log. A different one means the dice were just thrown.
LandlordEvent? _lastRoll(LandlordBoard b) {
  for (final e in b.events.reversed) {
    if (e.kind == LandlordEventKind.rolled) return e;
  }
  return null;
}

/// How long the dice tumble before the token starts to walk.
const _tumble = Duration(milliseconds: 950);

/// One hop from a space to the next; the jump to jail is one glide.
const _hop = Duration(milliseconds: 170);
const _glide = Duration(milliseconds: 560);

/// Further than this many spaces, a token runs: quicker hops, the whole way
/// round in about [_run].
const _maxHops = 12;
const _run = Duration(milliseconds: 1500);

/// How long a drawn card is shown before the token follows it.
const _read = Duration(milliseconds: 1100);

/// A beat on the Go To Jail space before the jump.
const _beat = Duration(milliseconds: 300);

/// Each hop of an [n]-space walk.
Duration _hopFor(int n) => n <= _maxHops ? _hop : _run ~/ n;

/// One stretch of a token's move: to [to], starting [at] after the board
/// changed, hopping forward (or [back]) space by space, or in one [glide].
@immutable
class _Leg {
  const _Leg(this.to, this.at, {this.back = false, this.glide = false});

  final int to;
  final Duration at;
  final bool back, glide;

  int stepsFrom(int from) => back ? (from - to) % 40 : (to - from) % 40;

  Duration timeFrom(int from) {
    final n = stepsFrom(from);
    if (n == 0) return Duration.zero;
    return glide ? _glide : _hopFor(n) * n;
  }
}

/// How one move plays out on the board: each token's legs, when a drawn card
/// is dealt, each balance's changes in turn, and when the tokens have all
/// arrived (a deed is dealt then).
class _Motion {
  const _Motion(this.legs, this.card, this.arrival, this.money);

  static const none = _Motion({}, Duration.zero, Duration.zero, {});

  final Map<Side, List<_Leg>> legs;
  final Duration card, arrival;

  /// Per player, each change to their cash and when it shows.
  final Map<Side, List<(Duration, int)>> money;
}

bool _sameEvent(LandlordEvent a, LandlordEvent b) =>
    identical(a, b) ||
    (a.actor == b.actor && a.kind == b.kind && a.space == b.space && a.amount == b.amount && a.dice == b.dice && a.card == b.card && a.other == b.other);

/// The events [now] has that [before] didn't. The log keeps only its newest
/// events, so this finds where [before]'s last few end up in [now].
List<LandlordEvent> _newEvents(LandlordBoard before, LandlordBoard now) {
  final a = before.events, b = now.events;
  if (a.isEmpty) return b;
  final k = min(4, a.length);
  for (var end = b.length; end >= k; end--) {
    var match = true;
    for (var j = 1; j <= k && match; j++) {
      match = _sameEvent(b[end - j], a[a.length - j]);
    }
    if (match) return b.sublist(end);
  }
  return const [];
}

/// Where card [c] sends a token on space [at], or null if it doesn't move it
/// (jail is its own event).
int? _cardTarget(LandlordCard c, int at) {
  int next(List<int> targets) => targets.firstWhere((t) => t > at, orElse: () => targets.first);
  return switch (c) {
    LandlordCard.luckToStart || LandlordCard.fundToStart => 0,
    LandlordCard.luckToNettle => 24,
    LandlordCard.luckToFern => 11,
    LandlordCard.luckToSouthStation => 5,
    LandlordCard.luckToVista => 39,
    LandlordCard.luckToUtility => next(groupSpaces(LandlordGroup.utility)),
    LandlordCard.luckToStationA || LandlordCard.luckToStationB => next(groupSpaces(LandlordGroup.station)),
    LandlordCard.luckBack3 => (at + 37) % 40,
    _ => null,
  };
}

/// Each player's cash change from [e]: who gains and who pays.
Iterable<(Side, int)> _cashOf(LandlordEvent e) sync* {
  final n = e.amount ?? 0;
  if (n == 0) return;
  switch (e.kind) {
    case LandlordEventKind.passedStart ||
        LandlordEventKind.pot ||
        LandlordEventKind.mortgaged ||
        LandlordEventKind.sold:
      yield (e.actor, n);
    case LandlordEventKind.collected:
      yield (e.actor, n);
      if (e.other case final o?) yield (o, -n);
    case LandlordEventKind.rent ||
        LandlordEventKind.tax ||
        LandlordEventKind.paid ||
        LandlordEventKind.bail ||
        LandlordEventKind.debtPaid ||
        LandlordEventKind.interest:
      yield (e.actor, -n);
      if (e.other case final o?) yield (o, n);
    case LandlordEventKind.bought || LandlordEventKind.unmortgaged || LandlordEventKind.built:
      yield (e.actor, -n);
    default:
  }
}

/// Changes to one balance closer together than this are spread out, so
/// each one is seen.
const _moneyGap = Duration(milliseconds: 1000);

/// Plans how the change from [before] to [now] is shown: after a roll the
/// dice tumble and the token walks to the space rolled; a drawn card is
/// dealt and read, then the token follows it (round the board, or back 3); a
/// trip to jail lands first, then jumps. Each payment shows when it happens:
/// Start's salary as the token passes it, rent or tax as it lands.
_Motion _plan(LandlordBoard before, LandlordBoard now) {
  final events = _newEvents(before, now);
  final at = {for (final p in Side.values) p: before.position(p)};
  final legs = <Side, List<_Leg>>{};
  final money = <Side, List<(Duration, int)>>{};
  final legFrom = Map<_Leg, int>.identity();
  var t = Duration.zero;
  var card = Duration.zero;

  void go(Side p, int to, {bool glide = false, bool backwards = false}) {
    final leg = _Leg(to, t, glide: glide, back: backwards);
    if (leg.stepsFrom(at[p]!) == 0) return;
    (legs[p] ??= []).add(leg);
    legFrom[leg] = at[p]!;
    t += leg.timeFrom(at[p]!);
    at[p] = to;
  }

  void pay(Side p, int n, Duration when) {
    final list = money[p] ??= [];
    if (list.isNotEmpty && when < list.last.$1 + _moneyGap) when = list.last.$1 + _moneyGap;
    list.add((when, n));
  }

  for (final e in events) {
    final p = e.actor;
    switch (e.kind) {
      case LandlordEventKind.rolled:
        t = _tumble;
        if (e.space != null && !(before.inJail(p) && e.space == 10)) go(p, e.space!);
      case LandlordEventKind.leftJail:
        t = _tumble;
        final d = e.dice!;
        go(p, (at[p]! + d.$1 + d.$2) % 40);
      case LandlordEventKind.drew:
        card = t;
        t += _read;
        if (_cardTarget(e.card!, at[p]!) case final to?) go(p, to, backwards: e.card == LandlordCard.luckBack3);
      case LandlordEventKind.jailed:
        if (at[p] != 10) {
          if (legs[p] != null) t += _beat;
          go(p, 10, glide: true);
        }
      case LandlordEventKind.passedStart:
        // As the token steps onto Start, partway through its last leg.
        var when = t;
        if (legs[p]?.last case final l? when !l.glide && !l.back) {
          final from = legFrom[l]!;
          final n = (0 - from) % 40;
          if (n > 0 && n <= l.stepsFrom(from)) when = l.at + _hopFor(l.stepsFrom(from)) * n;
        }
        pay(p, e.amount!, when);
      default:
        for (final (who, n) in _cashOf(e)) {
          pay(who, n, t);
        }
    }
  }
  // Anything the log doesn't explain (a trade's cash) lands at the end.
  for (final p in Side.values) {
    if (at[p] != now.position(p)) go(p, now.position(p));
    final explained = (money[p] ?? const []).fold<int>(0, (sum, c) => sum + c.$2);
    final rest = now.cash(p) - before.cash(p) - explained;
    if (rest != 0) pay(p, rest, t);
  }
  return _Motion(legs, card, t, money);
}

/// The outer edge of a space facing [dir] inward.
Alignment _outerOf(AxisDirection dir) => switch (dir) {
  AxisDirection.up => Alignment.bottomCenter,
  AxisDirection.down => Alignment.topCenter,
  AxisDirection.left => Alignment.centerRight,
  AxisDirection.right => Alignment.centerLeft,
};

/// A token's diameter on a board of unit [u].
double _tokenSize(double u) => u * 0.4;

/// Where token [k] of [count] on space [i] sits, in board pixels: under the
/// name on corners and side spaces, on the outer half of top and bottom ones.
Offset _tokenCentre(int i, int k, int count, _Ring ring) {
  var r = ring.rect(i);
  final two = count == 2;
  if (i % 10 == 0) return Alignment(two ? (k == 0 ? -0.35 : 0.35) : 0, 0.7).withinRect(r);
  final s = landlordSpaces[i];
  final dir = _inward(i);
  if (s.group != null && s.group!.buildable) {
    // The colour band takes the inward 26%.
    r = switch (dir) {
      AxisDirection.up => Rect.fromLTRB(r.left, r.top + r.height * 0.26, r.right, r.bottom),
      AxisDirection.down => Rect.fromLTRB(r.left, r.top, r.right, r.bottom - r.height * 0.26),
      AxisDirection.left => Rect.fromLTRB(r.left + r.width * 0.26, r.top, r.right, r.bottom),
      AxisDirection.right => Rect.fromLTRB(r.left, r.top, r.right - r.width * 0.26, r.bottom),
    };
  }
  final outer = _outerOf(dir);
  final vertical = dir == AxisDirection.up || dir == AxisDirection.down;
  final a = vertical ? Alignment(two ? (k == 0 ? -0.5 : 0.5) : 0, 0.55 * outer.y) : Alignment(-0.6 * outer.x + (two ? (k == 0 ? -0.3 : 0.3) : 0), 0.55);
  return a.withinRect(r);
}

/// One step of a walk: from space [from] to [to], over [startMs, endMs).
class _Step {
  const _Step(this.from, this.to, this.startMs, this.ms, this.lift);

  final int from, to, startMs, ms;

  /// How high it arcs, in token diameters.
  final double lift;

  int get endMs => startMs + ms;
}

/// A player's token at [target]. When [legs] changes it plays them: a hop
/// per space with a little arc (quicker when running a long way), or one
/// high glide for the jump to jail.
class _Walker extends StatefulWidget {
  const _Walker({super.key, required this.side, required this.target, required this.legs, required this.centreOf, required this.size});

  final Side side;
  final int target;

  /// This move's legs, or empty when the token didn't move.
  final List<_Leg> legs;
  final Offset Function(int space) centreOf;
  final double size;

  @override
  State<_Walker> createState() => _WalkerState();
}

class _WalkerState extends State<_Walker> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);

  /// Where the token rests, or where the current walk began.
  late int _at = widget.target;

  /// The walk being played; empty when resting.
  List<_Step> _steps = const [];

  @override
  void didUpdateWidget(_Walker old) {
    super.didUpdateWidget(old);
    if (!identical(widget.legs, old.legs) && widget.legs.isNotEmpty) {
      _walk(from: old.target);
    } else if (widget.target != old.target && widget.legs.isEmpty) {
      _c.stop();
      setState(() {
        _at = widget.target;
        _steps = const [];
      });
    }
  }

  void _walk({required int from}) {
    _c.stop();
    if (_still(context)) {
      _at = widget.target;
      _steps = const [];
      return;
    }
    final steps = <_Step>[];
    var here = from;
    for (final l in widget.legs) {
      final start = l.at.inMilliseconds;
      final n = l.stepsFrom(here);
      if (l.glide) {
        steps.add(_Step(here, l.to, start, _glide.inMilliseconds, 1.6));
      } else {
        final h = _hopFor(n).inMilliseconds;
        final lift = 0.55 * min(1.0, h / _hop.inMilliseconds + 0.3);
        for (var i = 0; i < n; i++) {
          final next = (here + (l.back ? -1 : 1) + 40) % 40;
          steps.add(_Step(here, next, start + i * h, h, lift));
          here = next;
        }
      }
      here = l.to;
    }
    if (steps.isEmpty) {
      _at = widget.target;
      _steps = const [];
      return;
    }
    _at = from;
    _steps = steps;
    _c.duration = Duration(milliseconds: steps.last.endMs);
    _c.forward(from: 0).whenCompleteOrCancel(() {
      if (mounted && _c.isCompleted) {
        setState(() {
          _at = widget.target;
          _steps = const [];
        });
      }
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget _disc(double lift) {
    final d = widget.size;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: landlordTokenColor(context, widget.side),
        shape: BoxShape.circle,
        border: Border.all(color: _Palette.paper, width: d * 0.1),
        boxShadow: [BoxShadow(color: const Color(0x66000000), blurRadius: 2 + lift * 0.35, offset: Offset(0, 1 + lift * 0.45))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.size;
    if (_steps.isEmpty) {
      // Resting: slide aside smoothly when the other token arrives.
      final p = widget.centreOf(_at);
      return AnimatedPositioned(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        left: p.dx - d / 2,
        top: p.dy - d / 2,
        width: d,
        height: d,
        child: IgnorePointer(child: _disc(0)),
      );
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final ms = _c.value * _c.duration!.inMilliseconds;
        var p = widget.centreOf(_at);
        var lift = 0.0;
        for (final s in _steps) {
          if (ms < s.startMs) break;
          if (ms >= s.endMs) {
            p = widget.centreOf(s.to);
            continue;
          }
          final t = (ms - s.startMs) / s.ms;
          p = Offset.lerp(widget.centreOf(s.from), widget.centreOf(s.to), Curves.easeInOut.transform(t))!;
          lift = sin(pi * t) * d * s.lift;
          break;
        }
        final grow = 1 + lift / d * 0.18;
        return Positioned(
          left: p.dx - d * grow / 2,
          top: p.dy - d * grow / 2 - lift,
          width: d * grow,
          height: d * grow,
          child: IgnorePointer(child: _disc(lift)),
        );
      },
    );
  }
}

/// Two dice, thrown in whenever [roll] (the roll event) changes: they fly
/// in from either side on an arc, spinning with their faces flickering,
/// then land with a squash and a couple of shrinking bounces. Before the
/// first roll ([values] null) they wait dimmed and blank.
class _Dice extends StatefulWidget {
  const _Dice({required this.values, required this.roll});

  final (int, int)? values;
  final Object? roll;

  @override
  State<_Dice> createState() => _DiceState();
}

class _DiceState extends State<_Dice> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: _tumble, value: 1);

  @override
  void didUpdateWidget(_Dice old) {
    super.didUpdateWidget(old);
    if (widget.roll != null && !identical(widget.roll, old.roll) && !_still(context)) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// One die on its own clock (the second starts [lag] later), thrown from
  /// [fromX] pixels to the side.
  Widget _die(int real, int salt, double fromX, double lag) {
    final t = ((_c.value - lag) / (1 - lag)).clamp(0.0, 1.0);
    const land = 0.6;
    final double x, y, angle, squash;
    final int face;
    if (t < land) {
      final f = t / land;
      x = fromX * (1 - Curves.easeOut.transform(f));
      y = -sin(pi * f) * 44 - (1 - f) * 8;
      angle = (1 - Curves.easeOut.transform(f)) * 4 * pi * fromX.sign;
      face = (real + (t * 24).floor() * (salt + 2) + salt) % 6 + 1;
      squash = 1;
    } else {
      final f = (t - land) / (1 - land);
      final fade = pow(1 - f, 2).toDouble();
      x = 0;
      y = -sin(f * pi * 2.4).abs() * 12 * fade;
      angle = sin(f * pi * 3) * 0.2 * fade * fromX.sign;
      face = real;
      squash = f < 0.12 ? 1 - 0.14 * sin(f / 0.12 * pi) : 1;
    }
    final height = -y;
    return SizedBox(
      width: 40,
      height: 40,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // The shadow stays on the felt and shrinks as the die rises.
          Positioned(
            left: 2 + x,
            width: 36,
            bottom: -5,
            height: 8,
            child: Transform.scale(
              scale: 1 - min(height, 50) / 80,
              child: DecoratedBox(
                decoration: BoxDecoration(color: Color.fromRGBO(0, 0, 0, 0.35 - min(height, 50) / 250), borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
          Transform.translate(
            offset: Offset(x, y),
            child: Transform.rotate(
              angle: angle,
              child: Transform.scale(scaleX: 2 - squash, scaleY: squash, alignment: Alignment.bottomCenter, child: _Die(face)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.values;
    if (v == null) {
      return const Opacity(
        opacity: 0.3,
        child: Row(mainAxisSize: MainAxisSize.min, children: [_Die(0), SizedBox(width: 10), _Die(0)]),
      );
    }
    final (a, b) = v;
    return Semantics(
      label: 'Dice: $a and $b',
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Row(mainAxisSize: MainAxisSize.min, children: [_die(a, 1, -80, 0), const SizedBox(width: 10), _die(b, 3, 80, 0.08)]),
      ),
    );
  }
}

/// How long a balance takes to count, pulse and float its change away.
const _counting = Duration(milliseconds: 1500);

const _gain = Color(0xFF8BE3A7), _loss = Color(0xFFFF9C8F);

/// [cash], playing [changes] in turn (each at its time after the board
/// changed): the number swells and glows green or red as it counts, and the
/// change rises off it on a pill. +200 then −200 is two moments, not none.
class _Cash extends StatefulWidget {
  const _Cash({required this.cash, required this.style, required this.changes});

  final int cash;
  final TextStyle? style;
  final List<(Duration, int)> changes;

  @override
  State<_Cash> createState() => _CashState();
}

class _CashState extends State<_Cash> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);

  /// The changes playing: when each starts (ms), the balance before it, and
  /// the change.
  List<(int, int, int)> _steps = const [];

  @override
  void didUpdateWidget(_Cash old) {
    super.didUpdateWidget(old);
    if (identical(widget.changes, old.changes) && widget.cash == old.cash) return;
    final changes = widget.changes.where((c) => c.$2 != 0).toList();
    if (changes.isEmpty || _still(context)) {
      if (widget.cash != old.cash || changes.isEmpty) {
        _c.stop();
        _steps = const [];
      }
      return;
    }
    // Count back from the new balance, so the steps always end on it.
    var bal = widget.cash - changes.fold<int>(0, (sum, c) => sum + c.$2);
    _steps = [];
    for (final (at, n) in changes) {
      _steps.add((at.inMilliseconds, bal, n));
      bal += n;
    }
    _c.duration = Duration(milliseconds: _steps.last.$1) + _counting;
    _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        var shown = widget.cash;
        var t = 1.0;
        var delta = 0;
        if (_c.isAnimating && _steps.isNotEmpty) {
          final ms = _c.value * _c.duration!.inMilliseconds;
          shown = _steps.first.$2;
          for (final (at, from, n) in _steps) {
            if (ms < at) break;
            t = ((ms - at) / _counting.inMilliseconds).clamp(0.0, 1.0);
            delta = n;
            shown = (from + n * Curves.easeOutCubic.transform((t / 0.55).clamp(0.0, 1.0))).round();
          }
        }
        final live = delta != 0 && t < 1;
        final up = delta > 0;
        final tint = up ? _gain : _loss;
        // Swell in fast, settle slowly; the glow fades with it.
        final pulse = live ? sin(pi * Curves.easeOut.transform((t / 0.7).clamp(0.0, 1.0))) : 0.0;
        final base = widget.style?.color ?? DefaultTextStyle.of(context).style.color ?? Colors.white;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Transform.scale(
              scale: 1 + 0.25 * pulse,
              alignment: Alignment.centerLeft,
              child: Text(
                money(shown),
                style: widget.style?.copyWith(
                  color: Color.lerp(base, tint, pulse),
                  shadows: [
                    if (pulse > 0)
                      Shadow(
                        color: tint.withValues(alpha: 0.7 * pulse),
                        blurRadius: 14 * pulse,
                      ),
                  ],
                ),
              ),
            ),
            if (live)
              Positioned(
                left: 0,
                top: -26 - 22 * Curves.easeOut.transform(t),
                child: Opacity(
                  opacity: 1 - Curves.easeIn.transform(((t - 0.5) / 0.5).clamp(0.0, 1.0)),
                  child: Transform.scale(
                    scale: 0.6 + 0.4 * Curves.elasticOut.transform((t / 0.4).clamp(0.0, 1.0)),
                    alignment: Alignment.bottomLeft,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(99)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                        child: Text(
                          '${up ? '+' : '−'}${money(delta.abs())}',
                          style: widget.style?.copyWith(fontSize: 15, fontWeight: FontWeight.w800, color: const Color(0xFF14231A), shadows: const []),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// [child] dealt onto the felt after [delay]: it drops in, turning straight.
class _Dealt extends StatelessWidget {
  const _Dealt({super.key, required this.delay, required this.child});

  final Duration delay;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (_still(context)) return child;
    const deal = 420;
    final wait = delay.inMilliseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: wait + deal),
      builder: (context, v, child) {
        final t = ((v * (wait + deal) - wait) / deal).clamp(0.0, 1.0);
        final e = Curves.easeOutBack.transform(t);
        return Opacity(
          opacity: Curves.easeOut.transform(t),
          child: Transform.translate(
            offset: Offset(0, (1 - e) * -22),
            child: Transform.rotate(
              angle: (1 - e) * -0.12,
              child: Transform.scale(scale: 0.85 + 0.15 * e, child: child),
            ),
          ),
        );
      },
      child: child,
    );
  }
}

/// The newest card drawn this turn (since the last end of turn), if any.
LandlordEvent? _drawnThisTurn(LandlordBoard b) {
  for (final e in b.events.reversed) {
    if (e.kind == LandlordEventKind.endTurn) return null;
    if (e.kind == LandlordEventKind.drew && e.card != null) return e;
  }
  return null;
}

/// A Luck or Family Fund card, face up.
class _CardFace extends StatelessWidget {
  const _CardFace({required this.card});

  final LandlordCard card;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final luck = card.deck == LandlordDeck.luck;
    final face = luck ? const Color(0xFFF6CF5A) : const Color(0xFF8FD0EC);
    final edge = luck ? const Color(0xFFC99A1E) : const Color(0xFF3E93BA);
    return Container(
      width: 210,
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 11),
      decoration: BoxDecoration(
        color: face,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: edge, width: 2),
        boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 6, offset: Offset(0, 3))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(landlordDeckIcon(card.deck), size: 16, color: _Palette.ink),
              const SizedBox(width: 6),
              Text(
                card.deck.title,
                style: theme.textTheme.labelLarge?.copyWith(color: _Palette.ink, fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            card.text,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: _Palette.ink, fontWeight: FontWeight.w600, height: 1.25),
          ),
        ],
      ),
    );
  }
}
