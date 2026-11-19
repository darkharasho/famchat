import 'dart:async';
import 'dart:math';

import 'package:material_ui/material_ui.dart';

import '../../landlord/landlord.dart';
import '../../rules.dart';
import '../dots_and_boxes_view.dart';
import 'landlord_log.dart';
import 'space_sheet.dart';
import 'trade_sheet.dart';

part 'landlord_motion.dart';

/// The board is a printed object on a table, the same in light and dark
/// mode: paper spaces around a green felt centre.
abstract final class _Palette {
  static const paper = Color(0xFFE9EDE6);
  static const ink = Color(0xFF1B231F);
  static const inkMuted = Color(0xFF4C5A52);
  static const line = Color(0xFFB4BFB6);
  static const felt = Color(0xFF1F3A2F);
  static const feltRaised = Color(0xFF29483B);
  static const feltHigh = Color(0xFF325546);
  static const onFelt = Color(0xFFF1F4EF);
  static const onFeltMuted = Color(0xFFB5C7BC);
  static const gold = Color(0xFFE9B949);
  static const onGold = Color(0xFF2B2000);
}

/// [base] for the paper spaces: dark ink, light token colours.
ThemeData _paperTheme(ThemeData base) => base.copyWith(
  colorScheme: base.colorScheme.copyWith(
    brightness: Brightness.light,
    surface: _Palette.paper,
    surfaceContainerLow: _Palette.paper,
    onSurface: _Palette.ink,
    onSurfaceVariant: _Palette.inkMuted,
    outlineVariant: _Palette.line,
  ),
  textTheme: base.textTheme.apply(bodyColor: _Palette.ink, displayColor: _Palette.ink),
);

/// [base] for the felt centre: light text, gold actions, bright tokens.
ThemeData _feltTheme(ThemeData base) {
  const muted = _Palette.onFeltMuted;
  return base.copyWith(
    colorScheme: base.colorScheme.copyWith(
      brightness: Brightness.dark,
      primary: _Palette.gold,
      onPrimary: _Palette.onGold,
      surface: _Palette.felt,
      surfaceContainer: _Palette.feltRaised,
      surfaceContainerHigh: _Palette.feltHigh,
      onSurface: _Palette.onFelt,
      onSurfaceVariant: muted,
      outline: muted,
      outlineVariant: _Palette.feltHigh,
      inverseSurface: const Color(0xFFF7F7F2),
      onInverseSurface: _Palette.ink,
    ),
    textTheme: base.textTheme.apply(bodyColor: _Palette.onFelt, displayColor: _Palette.onFelt),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: base.outlinedButtonTheme.style?.copyWith(
        foregroundColor: const WidgetStatePropertyAll(_Palette.onFelt),
        side: const WidgetStatePropertyAll(BorderSide(color: muted)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: base.textButtonTheme.style?.copyWith(
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
        foregroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.disabled) ? muted.withValues(alpha: 0.5) : _Palette.gold),
      ),
    ),
  );
}

/// A player's token colour (red for the first player, blue for the second).
Color landlordTokenColor(BuildContext context, Side s) => DotsAndBoxesView.sideColor(context, s);

/// The board's ring of spaces in pixels. Start is bottom right; play runs
/// clockwise (left along the bottom).
///
/// Square when the space is about square: 13 units each way, corners 2×2,
/// edges 1×2. Otherwise it stretches (up to 1.75:1) to fill the space: on a
/// tall phone the top and bottom rows get deeper (their names turned to run
/// along them) and the sides wider and taller; on a wide screen the top and
/// bottom spaces get wider and the sides wider.
class _Ring {
  const _Ring._(this.width, this.height, this.side, this.depth, this.tall);

  factory _Ring(Size box) {
    final w = box.width, h = box.height;
    if (h > w * 1.15) {
      final u = w / 14;
      return _Ring._(w, min(h, w * 1.75), u * 2.5, u * 2.8, true);
    }
    if (w > h * 1.15) {
      final u = h / 13;
      return _Ring._(min(w, h * 1.75), h, u * 2.5, u * 2, false);
    }
    final u = box.shortestSide / 13;
    return _Ring._(box.shortestSide, box.shortestSide, u * 2, u * 2, false);
  }

  final double width, height;

  /// The width of the left and right columns (and the corners).
  final double side;

  /// The height of the top and bottom rows (and the corners).
  final double depth;

  /// Stretched for a tall screen.
  final bool tall;

  /// A top or bottom space's width.
  double get unit => (width - 2 * side) / 9;

  /// A left or right space's height.
  double get step => (height - 2 * depth) / 9;

  /// The size icons, labels and tokens scale with: a space's short side.
  double get scale => min(unit, step);

  Rect get centre => Rect.fromLTWH(side, depth, width - 2 * side, height - 2 * depth);

  Rect rect(int i) {
    final right = width - side, bottom = height - depth;
    if (i == 0) return Rect.fromLTWH(right, bottom, side, depth);
    if (i < 10) return Rect.fromLTWH(right - i * unit, bottom, unit, depth);
    if (i == 10) return Rect.fromLTWH(0, bottom, side, depth);
    if (i < 20) return Rect.fromLTWH(0, bottom - (i - 10) * step, side, step);
    if (i == 20) return Rect.fromLTWH(0, 0, side, depth);
    if (i < 30) return Rect.fromLTWH(side + (i - 21) * unit, 0, unit, depth);
    if (i == 30) return Rect.fromLTWH(right, 0, side, depth);
    return Rect.fromLTWH(right, depth + (i - 31) * step, side, step);
  }
}

/// Which edge of space [i] faces the centre (its colour band goes there).
AxisDirection _inward(int i) {
  if (i < 10) return AxisDirection.up;
  if (i < 20) return AxisDirection.right;
  if (i < 30) return AxisDirection.down;
  return AxisDirection.left;
}

/// The (first, second) display names with "You" for the viewer.
String _name((String, String) names, Side s) => s == Side.first ? names.$1 : names.$2;

/// A one-line summary of offer [o] seen by [viewer]: "You get Acorn Lane +
/// $50 · You give Cedar Street".
String offerSummary(LandlordOffer o, Side viewer, (String, String) names) {
  String part(int cash, List<int> spaces, int cards) => [
    for (final s in spaces) landlordSpaces[s].name,
    if (cash > 0) money(cash),
    if (cards > 0) cards == 1 ? 'a jail-free card' : '$cards jail-free cards',
  ].join(' + ');
  final mine = viewer == o.from;
  final gets = mine ? part(o.getCash, o.getSpaces, o.getCards) : part(o.giveCash, o.giveSpaces, o.giveCards);
  final gives = mine ? part(o.giveCash, o.giveSpaces, o.giveCards) : part(o.getCash, o.getSpaces, o.getCards);
  return [if (gets.isNotEmpty) 'You get $gets', if (gives.isNotEmpty) 'You give $gives'].join(' · ');
}

/// What is going on, for [viewer]: "Your turn", "Mom is deciding", "You owe
/// Mom $200 — sell or mortgage".
String landlordStatus(LandlordBoard b, Side viewer, (String, String) names) {
  final o = b.outcome;
  if (o != null) return o.winner == viewer ? 'You won' : '${_name(names, o.winner ?? viewer.other)} won';
  final who = b.toMove;
  final me = who == viewer;
  final n = _name(names, who);
  switch (b.phase) {
    case LandlordPhase.debt:
      final d = b.debts.first;
      final to = d.creditor == null ? 'the bank' : (d.creditor == viewer ? 'you' : _name(names, d.creditor!));
      return me ? 'You owe $to ${money(d.amount)} — sell or mortgage' : '$n owes $to ${money(d.amount)}';
    case LandlordPhase.trade:
      return me ? '${_name(names, who.other)} offers a trade' : '$n is considering your offer';
    case LandlordPhase.buy:
      return me ? 'Buy ${landlordSpaces[b.position(who)].name}?' : '$n is deciding';
    case LandlordPhase.roll || LandlordPhase.end:
      return me ? 'Your turn' : "$n's turn";
  }
}

/// Landlord: a square ring of 40 spaces with the dice, both balances, what's
/// happening and my actions in the middle. Tap a space for its card; Log,
/// Properties and Trade open sheets. Upcoming cards are never shown.
class LandlordView extends StatefulWidget {
  const LandlordView({
    super.key,
    required this.board,
    required this.mySide,
    required this.onPlay,
    required this.interactive,
    required this.thumbnail,
    this.names,
  });

  final LandlordBoard board;
  final Side? mySide;
  final void Function(Map<String, Object?> move) onPlay;
  final bool interactive, thumbnail;

  /// (first, second) players' display names, or null.
  final (String, String)? names;

  (String, String) get _names => names ?? ((mySide ?? Side.first) == Side.first ? ('You', 'Opponent') : ('Opponent', 'You'));

  bool get _canAct => interactive && mySide != null && board.outcome == null && board.toMove == mySide;

  bool _legal(Map<String, Object?> m) => _canAct && board.play(m) != null;

  /// How long action buttons ignore taps after the board changes, so a
  /// double tap can't also hit the button that appears under the finger.
  static const settleTime = Duration(milliseconds: 600);

  @override
  State<LandlordView> createState() => _LandlordViewState();
}

class _LandlordViewState extends State<LandlordView> {
  Timer? _settle;

  /// How the last change plays out: token legs, when a card is dealt, and
  /// when it has all arrived (money changes, a deed is dealt).
  _Motion _motion = _Motion.none;

  @override
  void didUpdateWidget(LandlordView old) {
    super.didUpdateWidget(old);
    if (!identical(old.board, widget.board)) {
      _motion = _plan(old.board, widget.board);
      _settle?.cancel();
      _settle = Timer(LandlordView.settleTime, () {
        if (mounted) setState(() => _settle = null);
      });
    }
  }

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final board = w.board, mySide = w.mySide, thumbnail = w.thumbnail;
    final theme = Theme.of(context);
    final me = mySide ?? Side.first;
    final names = w._names;
    final acting = board.outcome == null ? board.toMove : null;
    final balances = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Plate(name: _name(names, me), cash: board.cash(me), side: me, active: acting == me, changes: _motion.money[me] ?? const []),
        const SizedBox(width: 8),
        _Plate(
          name: _name(names, me.other),
          cash: board.cash(me.other),
          side: me.other,
          active: acting == me.other,
          changes: _motion.money[me.other] ?? const [],
        ),
      ],
    );
    if (thumbnail) {
      return Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                balances,
                const SizedBox(height: 4),
                Text(landlordStatus(board, me, names), style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        final ring = _Ring(box.biggest);
        final u = ring.scale;
        final paper = _paperTheme(theme);
        return Center(
          child: SizedBox(
            width: ring.width,
            height: ring.height,
            child: Stack(
              children: [
                const Positioned.fill(child: ColoredBox(color: _Palette.felt)),
                for (var i = 0; i < 40; i++)
                  Positioned.fromRect(
                    rect: ring.rect(i),
                    child: Theme(
                      data: paper,
                      child: _SpaceTile(
                        key: ValueKey('space-$i'),
                        board: board,
                        index: i,
                        unit: u,
                        turned: ring.tall,
                        onTap: () => showSpaceSheet(context, board, i, me, names, w._legal, w.onPlay),
                      ),
                    ),
                  ),
                Positioned.fromRect(
                  rect: ring.centre,
                  child: Padding(
                    padding: EdgeInsets.all(u * 0.25),
                    // Drawn 250 wide and scaled with the board (about full
                    // size on a phone, at most 1.35× on a big screen), so it
                    // doesn't change size between phases; only a centre
                    // too tall for the space shrinks.
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: SizedBox(
                        width: 250 * (8.5 * u / 250).clamp(0.5, 1.35),
                        child: FittedBox(
                          fit: BoxFit.fitWidth,
                          child: SizedBox(
                            width: 250,
                            child: Theme(
                              data: _feltTheme(theme),
                              child: _Centre(view: w, armed: _settle == null, balances: balances, host: context, motion: _motion),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Tokens ride above everything; the one whose turn it is on top.
                for (final p in [board.turn.other, board.turn])
                  Theme(
                    data: paper,
                    child: _Walker(
                      key: ValueKey('token-${p.name}'),
                      side: p,
                      target: board.position(p),
                      size: _tokenSize(u),
                      legs: _motion.legs[p] ?? const [],
                      centreOf: (i) {
                        final here = [
                          for (final q in Side.values)
                            if (board.position(q) == i) q,
                        ];
                        final k = here.indexOf(p);
                        return _tokenCentre(i, k < 0 ? 0 : k, k < 0 ? 1 : here.length, ring);
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Centre extends StatelessWidget {
  const _Centre({required this.view, required this.armed, required this.balances, required this.host, required this.motion});

  /// How the last change plays out: a card is dealt when the token reaches
  /// its space, a deed once the token has arrived.
  final _Motion motion;

  final LandlordView view;

  /// Above the felt theme: sheets and dialogs open from here so they keep
  /// the app's look.
  final BuildContext host;

  /// False just after the board changed: action taps are ignored.
  final bool armed;
  final Widget balances;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = view.board;
    final me = view.mySide ?? Side.first;
    final names = view._names;
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final dice = b.dice;
    final away = view.mySide == null ? const <LandlordEvent>[] : sinceMyLast(b.events, me);
    final shown = away.length > 3 ? away.sublist(away.length - 3) : away;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        balances,
        const SizedBox(height: 12),
        _Dice(values: dice, roll: _lastRoll(b)),
        const SizedBox(height: 10),
        if (_drawnThisTurn(b) case final draw?) ...[
          _Dealt(
            key: ObjectKey(draw),
            delay: motion.card,
            child: _CardFace(card: draw.card!),
          ),
          const SizedBox(height: 10),
        ],
        if (b.phase == LandlordPhase.buy) ...[
          _Dealt(
            key: ObjectKey(_lastRoll(b)),
            delay: motion.arrival,
            child: _Deed(index: b.position(b.turn)),
          ),
          const SizedBox(height: 10),
        ],
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(
              position: Tween(begin: const Offset(0, 0.35), end: Offset.zero).animate(a),
              child: child,
            ),
          ),
          child: KeyedSubtree(
            key: ValueKey(landlordStatus(b, me, names)),
            child: Text(
              landlordStatus(b, me, names),
              key: const Key('landlord-status'),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ),
        if (b.trade case final o?) ...[
          const SizedBox(height: 2),
          Text(offerSummary(o, me, names), textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
        ],
        const SizedBox(height: 8),
        Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: _actions(context)),
        if (shown.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text('While you were away', style: theme.textTheme.labelMedium),
          for (final e in shown)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(landlordLogIcon(e), size: 14, color: landlordTokenColor(context, e.actor)),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(landlordLog(e, names), style: small, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
          if (away.length > shown.length)
            TextButton(key: const Key('away-more'), onPressed: () => _showLog(host), child: Text('+${away.length - shown.length} more')),
        ],
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          children: [
            TextButton(key: const Key('open-log'), onPressed: () => _showLog(host), child: const Text('Log')),
            TextButton(
              key: const Key('open-properties'),
              onPressed: () => showPropertiesSheet(host, b, me, names, view._legal, view.onPlay, canAct: view._canAct),
              child: const Text('Properties'),
            ),
            if (view.mySide != null)
              TextButton(
                key: const Key('open-trade'),
                onPressed: view._canAct && b.turn == me && (b.phase == LandlordPhase.roll || b.phase == LandlordPhase.end)
                    ? () => showTradeSheet(host, b, me, names, view.onPlay)
                    : null,
                child: const Text('Trade'),
              ),
          ],
        ),
      ],
    );
  }

  List<Widget> _actions(BuildContext context) {
    final b = view.board;
    if (!view._canAct) return const [];
    final out = <Widget>[];
    void add(String key, String label, Map<String, Object?> move, {bool primary = true}) {
      if (!view._legal(move)) return;
      final child = Text(label);
      void tap() {
        if (armed) view.onPlay(move);
      }

      out.add(primary ? FilledButton(key: Key('act-$key'), onPressed: tap, child: child) : OutlinedButton(key: Key('act-$key'), onPressed: tap, child: child));
    }

    switch (b.phase) {
      case LandlordPhase.roll:
        add('pay_bail', 'Pay \$50 bail', {'a': 'pay_bail'}, primary: false);
        add('use_card', 'Use card', {'a': 'use_card'}, primary: false);
        add('roll', 'Roll', {'a': 'roll'});
      case LandlordPhase.buy:
        final price = landlordSpaces[b.position(b.turn)].price;
        add('buy', 'Buy for ${money(price)}', {'a': 'buy'});
        add('decline', "Don't buy", {'a': 'decline'}, primary: false);
      case LandlordPhase.trade:
        add('accept', 'Accept', {'a': 'accept'});
        add('reject', 'Reject', {'a': 'reject'}, primary: false);
      case LandlordPhase.end:
        add('end_turn', 'End turn', {'a': 'end_turn'});
      case LandlordPhase.debt:
        out.add(
          FilledButton(
            key: const Key('act-raise'),
            onPressed: () => showPropertiesSheet(host, b, view.mySide ?? Side.first, view._names, view._legal, view.onPlay, canAct: view._canAct),
            child: const Text('Raise cash'),
          ),
        );
        out.add(OutlinedButton(key: const Key('act-bankrupt'), onPressed: () => _confirmBankrupt(host), child: const Text('Declare bankruptcy')));
    }
    return out;
  }

  Future<void> _confirmBankrupt(BuildContext context) async {
    final names = view._names;
    final other = _name(names, (view.mySide ?? Side.first).other);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Declare bankruptcy?'),
        content: Text('$other wins the game.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Declare')),
        ],
      ),
    );
    if (ok == true) view.onPlay(const {'a': 'bankrupt'});
  }

  void _showLog(BuildContext context) {
    final names = view._names;
    final events = view.board.events.reversed.toList();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.6,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Log', style: Theme.of(context).textTheme.titleMedium),
              ),
              Expanded(
                child: events.isEmpty
                    ? const Center(child: Text('Nothing yet'))
                    : ListView.builder(
                        itemCount: events.length,
                        itemBuilder: (context, i) {
                          final e = events[i];
                          final c = landlordTokenColor(context, e.actor);
                          return ListTile(
                            dense: true,
                            leading: CircleAvatar(
                              radius: 15,
                              backgroundColor: c.withValues(alpha: 0.16),
                              child: Icon(landlordLogIcon(e), size: 17, color: c),
                            ),
                            title: Text(landlordLog(e, names)),
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
}

/// One space on the ring: colour band, short name, owner dot, buildings and
/// tokens. Mortgaged spaces are dimmed.
class _SpaceTile extends StatelessWidget {
  const _SpaceTile({super.key, required this.board, required this.index, required this.unit, this.turned = false, required this.onTap});

  final LandlordBoard board;

  /// One board unit in pixels (a side tile is one unit wide); labels scale with it.
  final double unit;

  /// Top and bottom names run up the space (a tall phone's deep, narrow rows).
  final bool turned;
  final int index;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = landlordSpaces[index];
    final owner = board.owner(index);
    final level = board.level(index);
    final band = s.group != null && s.group!.buildable ? s.group!.color : null;
    final dir = _inward(index);
    final vertical = dir == AxisDirection.up || dir == AxisDirection.down;
    // A tall phone's top and bottom names (and icons) run up the space.
    final turn = turned && vertical && index % 10 != 0;
    final label = switch (s.kind) {
      SpaceKind.card => s.deck == LandlordDeck.luck ? 'Luck' : 'Fund',
      SpaceKind.tax => 'Tax',
      SpaceKind.station => s.name.split(' ').first,
      SpaceKind.utility => index == 12 ? 'Power' : 'Water',
      SpaceKind.start => 'Start',
      SpaceKind.jail => 'Jail',
      SpaceKind.rest => 'Rest',
      SpaceKind.goToJail => 'Go to\nJail',
      SpaceKind.property => s.name.split(' ').first,
    };
    final icon = switch (s.kind) {
      SpaceKind.start => Icons.west,
      SpaceKind.jail => Icons.lock_outline,
      SpaceKind.rest => Icons.local_cafe_outlined,
      SpaceKind.goToJail => Icons.local_police_outlined,
      SpaceKind.card => landlordDeckIcon(s.deck!),
      SpaceKind.tax => Icons.account_balance_outlined,
      SpaceKind.station => Icons.train_outlined,
      SpaceKind.utility => index == 12 ? Icons.bolt : Icons.water_drop_outlined,
      SpaceKind.property => null,
    };
    final tokens = [
      for (final p in Side.values)
        if (board.position(p) == index) p,
    ];
    // The outer edge, where the owner's bar sits.
    final outer = _outerOf(dir);
    final body = Stack(
      fit: StackFit.expand,
      children: [
        Padding(
          padding: const EdgeInsets.all(1.5),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: switch ((index % 10 == 0, vertical, tokens.isEmpty)) {
              (true, _, _) => const Alignment(0, -0.4),
              // A side space with a token: the name moves up out of its way.
              (false, false, false) => Alignment(-0.6 * outer.x, -0.75),
              _ => Alignment(-0.6 * outer.x, -0.6 * outer.y),
            },
            child: FittedBox(
              fit: BoxFit.scaleDown,
              // Corners and top/bottom spaces: icon over the name; side
              // spaces (wide and short): icon before it.
              child: RotatedBox(
                quarterTurns: turn ? 3 : 0,
                child: Flex(
                  direction: index % 10 == 0 || (vertical && !turn) ? Axis.vertical : Axis.horizontal,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: unit * (index % 10 == 0 ? 0.7 : 0.5), color: theme.colorScheme.onSurfaceVariant),
                      if (!(index % 10 == 0 || (vertical && !turn))) SizedBox(width: unit * 0.08),
                    ],
                    Text(
                      label,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: turned ? (unit * 0.5).clamp(12.0, 20.0) : (unit * 0.38).clamp(10.0, 20.0),
                        height: 1.1,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (owner != null)
          Align(
            alignment: outer,
            // A new owner's bar grows out from the middle.
            child: TweenAnimationBuilder<double>(
              key: ValueKey(owner),
              tween: Tween(begin: _still(context) ? 1 : 0, end: 1),
              duration: const Duration(milliseconds: 450),
              curve: Curves.easeOutBack,
              builder: (context, g, child) =>
                  FractionallySizedBox(widthFactor: vertical ? 0.7 * g : 0.12, heightFactor: vertical ? 0.1 : 0.7 * g, child: child),
              child: DecoratedBox(
                decoration: BoxDecoration(color: landlordTokenColor(context, owner), borderRadius: BorderRadius.circular(2)),
              ),
            ),
          ),
      ],
    );
    Widget content = body;
    if (band != null) {
      final strip = Expanded(
        flex: 26,
        child: ColoredBox(
          color: band,
          child: _Buildings(level: level, vertical: vertical),
        ),
      );
      final rest = Expanded(flex: 74, child: body);
      content = Flex(
        direction: vertical ? Axis.vertical : Axis.horizontal,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: dir == AxisDirection.up || dir == AxisDirection.left ? [strip, rest] : [rest, strip],
      );
    }
    if (board.isMortgaged(index)) content = Opacity(opacity: 0.4, child: content);
    return Semantics(
      button: true,
      label: [
        s.name,
        if (owner != null) 'owned',
        if (level == 5) 'hotel' else if (level > 0) '$level houses',
        if (board.isMortgaged(index)) 'mortgaged',
      ].join(', '),
      child: InkWell(
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            border: Border.all(color: theme.colorScheme.outlineVariant, width: 0.5),
          ),
          child: ExcludeSemantics(child: content),
        ),
      ),
    );
  }
}

/// Houses (green dots) or a hotel (a red block) on a colour band.
class _Buildings extends StatelessWidget {
  const _Buildings({required this.level, required this.vertical});

  final int level;
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    if (level == 0) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, box) {
        final thin = vertical ? box.maxHeight : box.maxWidth;
        final d = thin * 0.55;
        final Widget piece = level == 5
            ? Container(
                width: vertical ? d * 2.2 : d,
                height: vertical ? d : d * 2.2,
                decoration: BoxDecoration(
                  color: const Color(0xFFC62828),
                  borderRadius: BorderRadius.circular(2),
                  border: Border.all(color: const Color(0xFFFFFFFF), width: 0.8),
                ),
              )
            : Flex(
                direction: vertical ? Axis.horizontal : Axis.vertical,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < level; i++)
                    Container(
                      width: d,
                      height: d,
                      margin: EdgeInsets.all(d * 0.12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2E7D32),
                        borderRadius: BorderRadius.circular(1.5),
                        border: Border.all(color: const Color(0xFFFFFFFF), width: 0.8),
                      ),
                    ),
                ],
              );
        return Center(
          child: FittedBox(fit: BoxFit.scaleDown, child: piece),
        );
      },
    );
  }
}

/// A player's name and cash. [active] (whoever must act) is outlined in
/// their token colour.
class _Plate extends StatelessWidget {
  const _Plate({required this.name, required this.cash, required this.side, required this.active, required this.changes});

  final String name;
  final int cash;

  /// This move's changes to the balance and when each shows.
  final List<(Duration, int)> changes;
  final Side side;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = landlordTokenColor(context, side);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 112,
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 7),
      decoration: BoxDecoration(
        color: active ? Color.alphaBlend(c.withValues(alpha: 0.14), theme.colorScheme.surfaceContainerHigh) : theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: active ? c : theme.colorScheme.outlineVariant, width: active ? 2 : 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: c, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: _Cash(
              cash: cash,
              changes: changes,
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
        ],
      ),
    );
  }
}

/// One die face with pips.
class _Die extends StatelessWidget {
  const _Die(this.value);

  final int value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExcludeSemantics(
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: theme.colorScheme.inverseSurface,
          borderRadius: BorderRadius.circular(9),
          boxShadow: [BoxShadow(color: theme.shadowColor.withValues(alpha: 0.25), blurRadius: 4, offset: const Offset(0, 2))],
        ),
        child: CustomPaint(painter: _PipPainter(value, theme.colorScheme.onInverseSurface)),
      ),
    );
  }
}

class _PipPainter extends CustomPainter {
  _PipPainter(this.value, this.color);

  final int value;
  final Color color;

  static const _pips = {
    1: [(1, 1)],
    2: [(0, 0), (2, 2)],
    3: [(0, 0), (1, 1), (2, 2)],
    4: [(0, 0), (2, 0), (0, 2), (2, 2)],
    5: [(0, 0), (2, 0), (1, 1), (0, 2), (2, 2)],
    6: [(0, 0), (2, 0), (0, 1), (2, 1), (0, 2), (2, 2)],
  };

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final step = size.width * 0.27;
    final r = size.width * 0.09;
    for (final (x, y) in _pips[value] ?? const <(int, int)>[]) {
      canvas.drawCircle(Offset(size.width / 2 + (x - 1) * step, size.height / 2 + (y - 1) * step), r, paint);
    }
  }

  @override
  bool shouldRepaint(_PipPainter old) => old.value != value || old.color != color;
}

/// The title deed for space [index], shown while its buyer decides.
class _Deed extends StatelessWidget {
  const _Deed({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = landlordSpaces[index];
    final band = s.group != null && s.group!.buildable ? s.group!.color : _Palette.line;
    final onBand = ThemeData.estimateBrightnessForColor(band) == Brightness.dark ? Colors.white : Colors.black;
    final rent = switch (s.kind) {
      SpaceKind.property => 'Rent ${money(s.rent[0])}, ${money(s.rent[0] * 2)} with the set',
      SpaceKind.station => 'Rent ${money(25)}, doubling per station',
      SpaceKind.utility => 'Rent 4× the dice, 10× with both',
      _ => '',
    };
    return Container(
      width: 200,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: _Palette.paper,
        borderRadius: BorderRadius.circular(6),
        boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 6, offset: Offset(0, 3))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: band,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Text(
              s.name,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(color: onBand, fontWeight: FontWeight.w800),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Column(
              children: [
                Text(
                  money(s.price),
                  style: theme.textTheme.headlineSmall?.copyWith(color: _Palette.ink, fontWeight: FontWeight.w800),
                ),
                if (rent.isNotEmpty)
                  Text(
                    rent,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: _Palette.inkMuted),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// For tests: how the change from [before] to [now] is shown. Each token's
/// stops in order (the space and whether it glides there), each balance's
/// changes (ms after the change, amount), when a drawn card is dealt and when
/// the tokens have all arrived.
@visibleForTesting
({Map<Side, List<(int, bool)>> stops, Map<Side, List<(int, int)>> money, int cardMs, int arrivalMs}) landlordMotion(LandlordBoard before, LandlordBoard now) {
  final m = _plan(before, now);
  return (
    stops: {
      for (final e in m.legs.entries) e.key: [for (final l in e.value) (l.to, l.glide)],
    },
    money: {
      for (final e in m.money.entries) e.key: [for (final (at, n) in e.value) (at.inMilliseconds, n)],
    },
    cardMs: m.card.inMilliseconds,
    arrivalMs: m.arrival.inMilliseconds,
  );
}
