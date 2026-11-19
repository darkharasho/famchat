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

/// One hop from a space to the next; a long jump (jail, a card) is one glide.
const _hop = Duration(milliseconds: 170);
const _glide = Duration(milliseconds: 560);

/// Further than this many spaces ahead, a token glides instead of hopping.
const _maxHops = 12;

/// How long a walk from [from] to [to] takes, after [delay].
Duration _walkTime(int from, int to, Duration delay) {
  final n = (to - from) % 40;
  if (n == 0) return Duration.zero;
  return delay + (n > _maxHops ? _glide : _hop * n);
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
Offset _tokenCentre(int i, int k, int count, double u) {
  final c = _cell(i);
  var r = Rect.fromLTWH(c.left * u, c.top * u, c.width * u, c.height * u);
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
  final a = vertical
      ? Alignment(two ? (k == 0 ? -0.5 : 0.5) : 0, 0.55 * outer.y)
      : Alignment(-0.6 * outer.x + (two ? (k == 0 ? -0.3 : 0.3) : 0), 0.55);
  return a.withinRect(r);
}

/// A player's token, walking to [target] when it changes: [delay], then a
/// hop per space with a little arc, or one high glide for a long jump.
class _Walker extends StatefulWidget {
  const _Walker({
    super.key,
    required this.side,
    required this.target,
    required this.centreOf,
    required this.size,
    required this.delay,
  });

  final Side side;
  final int target;
  final Offset Function(int space) centreOf;
  final double size;
  final Duration delay;

  @override
  State<_Walker> createState() => _WalkerState();
}

class _WalkerState extends State<_Walker> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);

  /// Where the token rests, or where the current walk began.
  late int _at = widget.target;

  /// The spaces still to step onto, in order; empty when resting.
  List<int> _path = const [];
  bool _gliding = false;
  int _delayMs = 0;

  @override
  void didUpdateWidget(_Walker old) {
    super.didUpdateWidget(old);
    if (widget.target != old.target) _walk(from: old.target);
  }

  void _walk({required int from}) {
    _c.stop();
    final n = (widget.target - from) % 40;
    if (n == 0 || _still(context)) {
      _at = widget.target;
      _path = const [];
      return;
    }
    _at = from;
    _gliding = n > _maxHops;
    _path = _gliding ? [widget.target] : [for (var i = 1; i <= n; i++) (from + i) % 40];
    _delayMs = widget.delay.inMilliseconds;
    _c.duration = _walkTime(from, widget.target, widget.delay);
    _c.forward(from: 0).whenCompleteOrCancel(() {
      if (mounted && _c.isCompleted) {
        setState(() {
          _at = widget.target;
          _path = const [];
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
        boxShadow: [
          BoxShadow(color: const Color(0x66000000), blurRadius: 2 + lift * 0.35, offset: Offset(0, 1 + lift * 0.45)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.size;
    if (_path.isEmpty) {
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
        final step = (_gliding ? _glide : _hop).inMilliseconds;
        final ms = _c.value * _c.duration!.inMilliseconds - _delayMs;
        var p = widget.centreOf(_at);
        var lift = 0.0;
        if (ms > 0) {
          final i = min(_path.length - 1, ms ~/ step);
          final t = ((ms - i * step) / step).clamp(0.0, 1.0);
          final from = widget.centreOf(i == 0 ? _at : _path[i - 1]);
          p = Offset.lerp(from, widget.centreOf(_path[i]), Curves.easeInOut.transform(t))!;
          lift = sin(pi * t) * d * (_gliding ? 1.6 : 0.55);
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
                decoration: BoxDecoration(
                  color: Color.fromRGBO(0, 0, 0, 0.35 - min(height, 50) / 250),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
          Transform.translate(
            offset: Offset(x, y),
            child: Transform.rotate(
              angle: angle,
              child: Transform.scale(
                scaleX: 2 - squash,
                scaleY: squash,
                alignment: Alignment.bottomCenter,
                child: _Die(face),
              ),
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
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [_die(a, 1, -80, 0), const SizedBox(width: 10), _die(b, 3, 80, 0.08)],
        ),
      ),
    );
  }
}

/// [cash], counting to each new value, with the change floating up off it.
class _Cash extends StatefulWidget {
  const _Cash({required this.cash, required this.style});

  final int cash;
  final TextStyle? style;

  @override
  State<_Cash> createState() => _CashState();
}

class _CashState extends State<_Cash> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
  late int _from = widget.cash;
  int _delta = 0;

  @override
  void didUpdateWidget(_Cash old) {
    super.didUpdateWidget(old);
    if (widget.cash != old.cash) {
      _from = old.cash;
      _delta = widget.cash - old.cash;
      if (_still(context)) {
        _c.value = 1;
      } else {
        _c.forward(from: 0);
      }
    }
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
        final t = _c.isAnimating ? _c.value : 1.0;
        final count = Curves.easeOutCubic.transform((t / 0.6).clamp(0.0, 1.0));
        final shown = (_from + (widget.cash - _from) * count).round();
        final up = _delta > 0;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Text(money(shown), style: widget.style),
            if (_c.isAnimating && _delta != 0)
              Positioned(
                right: -4,
                top: -18 - 14 * t,
                child: Opacity(
                  opacity: (1 - Curves.easeIn.transform(t)).clamp(0.0, 1.0),
                  child: Text(
                    '${up ? '+' : '−'}${money(_delta.abs())}',
                    style: widget.style?.copyWith(
                      fontSize: 13,
                      color: up ? const Color(0xFF8BE3A7) : const Color(0xFFFF9C8F),
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
