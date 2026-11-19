import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../landlord/landlord.dart';
import '../../rules.dart';
import '../dots_and_boxes_view.dart';
import 'landlord_log.dart';
import 'space_sheet.dart';
import 'trade_sheet.dart';

/// A player's token colour (red for the first player, blue for the second).
Color landlordTokenColor(BuildContext context, Side s) => DotsAndBoxesView.sideColor(context, s);

/// Where space [i] sits on a ring of 13 units: corners are 2×2, edges 1×2.
/// Start is bottom right; play runs clockwise (left along the bottom).
Rect _cell(int i) {
  if (i == 0) return const Rect.fromLTWH(11, 11, 2, 2);
  if (i < 10) return Rect.fromLTWH(11.0 - i, 11, 1, 2);
  if (i == 10) return const Rect.fromLTWH(0, 11, 2, 2);
  if (i < 20) return Rect.fromLTWH(0, 21.0 - i, 2, 1);
  if (i == 20) return const Rect.fromLTWH(0, 0, 2, 2);
  if (i < 30) return Rect.fromLTWH(i - 19.0, 0, 1, 2);
  if (i == 30) return const Rect.fromLTWH(11, 0, 2, 2);
  return Rect.fromLTWH(11, i - 29.0, 2, 1);
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
  return [
    if (gets.isNotEmpty) 'You get $gets',
    if (gives.isNotEmpty) 'You give $gives',
  ].join(' · ');
}

/// What is going on, for [viewer]: "Your turn", "Mom is bidding", "You owe
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
    case LandlordPhase.auction:
      final a = b.auction!;
      final high = a.highBidder == null
          ? 'no bids yet'
          : 'high bid ${money(a.high)} (${a.highBidder == viewer ? 'you' : _name(names, a.highBidder!)})';
      return '${landlordSpaces[a.space].name}: $high · ${me ? 'your bid' : '$n is bidding'}';
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

  (String, String) get _names =>
      names ?? ((mySide ?? Side.first) == Side.first ? ('You', 'Opponent') : ('Opponent', 'You'));

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

  @override
  void didUpdateWidget(LandlordView old) {
    super.didUpdateWidget(old);
    if (!identical(old.board, widget.board)) {
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
    final balances = Text(
      '${_name(names, me)} ${money(board.cash(me))} · ${_name(names, me.other)} ${money(board.cash(me.other))}',
      style: theme.textTheme.titleSmall,
      textAlign: TextAlign.center,
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
        final side = box.biggest.shortestSide;
        final u = side / 13;
        return Center(
          child: SizedBox.square(
            dimension: side,
            child: Stack(
              children: [
                Positioned.fill(child: ColoredBox(color: theme.colorScheme.surfaceContainerLowest)),
                for (var i = 0; i < 40; i++)
                  Positioned.fromRect(
                    rect: Rect.fromLTWH(_cell(i).left * u, _cell(i).top * u, _cell(i).width * u, _cell(i).height * u),
                    child: _SpaceTile(
                      key: ValueKey('space-$i'),
                      board: board,
                      index: i,
                      onTap: () => showSpaceSheet(context, board, i, me, names, w._legal, w.onPlay),
                    ),
                  ),
                Positioned.fromRect(
                  rect: Rect.fromLTWH(2 * u, 2 * u, 9 * u, 9 * u),
                  child: Padding(
                    padding: EdgeInsets.all(u * 0.25),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: SizedBox(
                        width: 320,
                        child: _Centre(view: w, armed: _settle == null, balances: balances),
                      ),
                    ),
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
  const _Centre({required this.view, required this.armed, required this.balances});

  final LandlordView view;

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
        if (dice != null)
          Text(
            '${String.fromCharCode(0x2680 + dice.$1 - 1)} ${String.fromCharCode(0x2680 + dice.$2 - 1)}',
            style: const TextStyle(fontFamily: 'NotoSansSymbols2', fontSize: 36, height: 1.1),
            semanticsLabel: 'Dice: ${dice.$1} and ${dice.$2}',
          ),
        const SizedBox(height: 4),
        balances,
        const SizedBox(height: 6),
        Text(
          landlordStatus(b, me, names),
          key: const Key('landlord-status'),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        if (b.trade case final o?) ...[
          const SizedBox(height: 2),
          Text(offerSummary(o, me, names), textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
        ],
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: _actions(context),
        ),
        if (shown.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text('While you were away', style: theme.textTheme.labelMedium),
          for (final e in shown)
            Text(landlordLog(e, names), style: small, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
          if (away.length > shown.length)
            TextButton(
              key: const Key('away-more'),
              onPressed: () => _showLog(context),
              child: Text('+${away.length - shown.length} more'),
            ),
        ],
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 4,
          children: [
            TextButton(
              key: const Key('open-log'),
              onPressed: () => _showLog(context),
              child: const Text('Log'),
            ),
            TextButton(
              key: const Key('open-properties'),
              onPressed: () => showPropertiesSheet(context, b, me, names, view._legal, view.onPlay),
              child: const Text('Properties'),
            ),
            if (view.mySide != null)
              TextButton(
                key: const Key('open-trade'),
                onPressed: view._canAct &&
                        b.turn == me &&
                        (b.phase == LandlordPhase.roll || b.phase == LandlordPhase.end)
                    ? () => showTradeSheet(context, b, me, names, view.onPlay)
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
      out.add(
        primary
            ? FilledButton(key: Key('act-$key'), onPressed: tap, child: child)
            : OutlinedButton(key: Key('act-$key'), onPressed: tap, child: child),
      );
    }

    switch (b.phase) {
      case LandlordPhase.roll:
        add('pay_bail', 'Pay \$50 bail', {'a': 'pay_bail'}, primary: false);
        add('use_card', 'Use card', {'a': 'use_card'}, primary: false);
        add('roll', 'Roll', {'a': 'roll'});
      case LandlordPhase.buy:
        final price = landlordSpaces[b.position(b.turn)].price;
        add('buy', 'Buy for ${money(price)}', {'a': 'buy'});
        add('decline', 'Auction', {'a': 'decline'}, primary: false);
      case LandlordPhase.auction:
        final high = b.auction!.high;
        for (final step in [1, 10, 50]) {
          add('bid-$step', '+${money(step)}', {'a': 'bid', 'amount': high + step});
        }
        if (view._legal({'a': 'bid', 'amount': high + 1})) {
          out.add(
            OutlinedButton(
              key: const Key('act-bid-custom'),
              onPressed: () => _bidDialog(context, high),
              child: const Text('Bid…'),
            ),
          );
        }
        add('pass', 'Pass', {'a': 'pass'}, primary: false);
      case LandlordPhase.trade:
        add('accept', 'Accept', {'a': 'accept'});
        add('reject', 'Reject', {'a': 'reject'}, primary: false);
      case LandlordPhase.end:
        add('end_turn', 'End turn', {'a': 'end_turn'});
      case LandlordPhase.debt:
        out.add(
          FilledButton(
            key: const Key('act-raise'),
            onPressed: () => showPropertiesSheet(
              context,
              b,
              view.mySide ?? Side.first,
              view._names,
              view._legal,
              view.onPlay,
            ),
            child: const Text('Raise cash'),
          ),
        );
        out.add(
          OutlinedButton(
            key: const Key('act-bankrupt'),
            onPressed: () => _confirmBankrupt(context),
            child: const Text('Declare bankruptcy'),
          ),
        );
    }
    return out;
  }

  Future<void> _bidDialog(BuildContext context, int high) async {
    final amount = await showDialog<int>(
      context: context,
      builder: (context) => _BidDialog(
        high: high,
        legal: (n) => view._legal({'a': 'bid', 'amount': n}),
      ),
    );
    if (amount != null) view.onPlay({'a': 'bid', 'amount': amount});
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
                        itemBuilder: (context, i) => ListTile(dense: true, title: Text(landlordLog(events[i], names))),
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
  const _SpaceTile({super.key, required this.board, required this.index, required this.onTap});

  final LandlordBoard board;
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
    final label = switch (s.kind) {
      SpaceKind.card => s.deck == LandlordDeck.luck ? 'Luck' : 'Fund',
      SpaceKind.tax => 'Tax',
      SpaceKind.station => '${s.name.split(' ').first}\nStn',
      SpaceKind.utility => index == 12 ? 'Power' : 'Water',
      SpaceKind.start => 'Start',
      SpaceKind.jail => 'Jail',
      SpaceKind.rest => 'Rest',
      SpaceKind.goToJail => 'Go to\nJail',
      SpaceKind.property => s.name.split(' ').first,
    };
    final tokens = [
      for (final p in Side.values)
        if (board.position(p) == index) p,
    ];
    // The outer edge, where the owner's bar sits.
    final outer = switch (dir) {
      AxisDirection.up => Alignment.bottomCenter,
      AxisDirection.down => Alignment.topCenter,
      AxisDirection.left => Alignment.centerRight,
      AxisDirection.right => Alignment.centerLeft,
    };
    final body = Stack(
      fit: StackFit.expand,
      children: [
        Padding(
          padding: const EdgeInsets.all(1.5),
          child: Align(
            alignment: index % 10 == 0 ? Alignment.center : Alignment(-0.6 * outer.x, -0.6 * outer.y),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(fontSize: 9, height: 1.1),
              ),
            ),
          ),
        ),
        if (owner != null)
          Align(
            alignment: outer,
            child: FractionallySizedBox(
              widthFactor: vertical ? 0.7 : 0.12,
              heightFactor: vertical ? 0.1 : 0.7,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: landlordTokenColor(context, owner),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        for (final (k, p) in tokens.indexed)
          Align(
            alignment: vertical
                ? Alignment(tokens.length == 2 ? (k == 0 ? -0.5 : 0.5) : 0, 0.55 * outer.y)
                : Alignment(0.55 * outer.x, tokens.length == 2 ? (k == 0 ? -0.5 : 0.5) : 0),
            child: FractionallySizedBox(
              widthFactor: vertical ? 0.5 : 0.25,
              heightFactor: vertical ? 0.25 : 0.5,
              child: FittedBox(
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: landlordTokenColor(context, p),
                    shape: BoxShape.circle,
                    border: Border.all(color: theme.colorScheme.surface, width: 1.5),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    Widget content = body;
    if (band != null) {
      final strip = Expanded(
        flex: 26,
        child: ColoredBox(color: band, child: _Buildings(level: level, vertical: vertical)),
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
        return Center(child: FittedBox(fit: BoxFit.scaleDown, child: piece));
      },
    );
  }
}

/// Asks for a bid of any amount above [high] that [legal] accepts.
class _BidDialog extends StatefulWidget {
  const _BidDialog({required this.high, required this.legal});

  final int high;
  final bool Function(int amount) legal;

  @override
  State<_BidDialog> createState() => _BidDialogState();
}

class _BidDialogState extends State<_BidDialog> {
  int? _amount;

  @override
  Widget build(BuildContext context) {
    final n = _amount;
    final ok = n != null && widget.legal(n);
    return AlertDialog(
      title: const Text('Your bid'),
      content: TextField(
        key: const Key('bid-amount'),
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(prefixText: '\$', helperText: 'More than ${money(widget.high)}'),
        onChanged: (v) => setState(() => _amount = int.tryParse(v.trim())),
        onSubmitted: (_) {
          if (ok) Navigator.pop(context, n);
        },
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const Key('bid-confirm'),
          onPressed: ok ? () => Navigator.pop(context, n) : null,
          child: const Text('Bid'),
        ),
      ],
    );
  }
}
