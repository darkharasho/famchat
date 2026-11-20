import 'package:material_ui/material_ui.dart';

import '../../landlord/landlord.dart';
import '../../rules.dart';
import 'landlord_log.dart';

String _owner((String, String) names, Side? s) => s == null ? 'The bank' : (s == Side.first ? names.$1 : names.$2);

/// Space [i]'s card: price, rents, owner and buildings, with Build / Sell /
/// Mortgage / Unmortgage for the ones [legal] allows me now.
Future<void> showSpaceSheet(
  BuildContext context,
  LandlordBoard b,
  int i,
  Side me,
  (String, String) names,
  bool Function(Map<String, Object?> move) legal,
  void Function(Map<String, Object?> move) onPlay,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
        child: SpaceCard(board: b, index: i, names: names, legal: legal, onPlay: onPlay),
      ),
    ),
  );
}

/// The body of [showSpaceSheet].
class SpaceCard extends StatelessWidget {
  const SpaceCard({
    super.key,
    required this.board,
    required this.index,
    required this.names,
    required this.legal,
    required this.onPlay,
  });

  final LandlordBoard board;
  final int index;
  final (String, String) names;
  final bool Function(Map<String, Object?> move) legal;
  final void Function(Map<String, Object?> move) onPlay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = landlordSpaces[index];
    final small = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final level = board.level(index);
    final rows = <(String, String)>[
      if (s.kind == SpaceKind.property) ...[
        ('Rent', money(s.rent[0])),
        ('With the full set', money(s.rent[0] * 2)),
        for (var h = 1; h <= 4; h++) ('With $h house${h == 1 ? '' : 's'}', money(s.rent[h])),
        ('With a hotel', money(s.rent[5])),
        ('House or hotel', '${money(s.houseCost)} each'),
      ],
      if (s.kind == SpaceKind.station)
        for (var n = 1; n <= 4; n++) ('$n station${n == 1 ? '' : 's'} owned', money(25 << (n - 1))),
      if (s.kind == SpaceKind.utility) ...[('One utility owned', '4× the dice'), ('Both owned', '10× the dice')],
      if (s.ownable) ('Mortgage value', money(s.mortgageValue)),
    ];
    final actions = [
      for (final (a, label) in [
        ('build', level == 4 ? 'Build a hotel' : 'Build'),
        ('sell', level == 5 ? 'Sell the hotel' : 'Sell a house'),
        ('mortgage', 'Mortgage'),
        ('unmortgage', 'Unmortgage'),
      ])
        if (legal({'a': a, 'space': index}))
          FilledButton(
            onPressed: () {
              onPlay({'a': a, 'space': index});
              Navigator.pop(context);
            },
            child: Text(label),
          ),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (s.group case final g? when g.buildable) Container(height: 10, color: g.color),
        const SizedBox(height: 8),
        Text(s.name, style: theme.textTheme.titleLarge),
        if (s.ownable) ...[
          Text(
            [
              if (s.price > 0) 'Price ${money(s.price)}',
              'Owner: ${_owner(names, board.owner(index))}',
              if (level == 5) 'Hotel' else if (level > 0) '$level house${level == 1 ? '' : 's'}',
              if (board.isMortgaged(index)) 'Mortgaged',
            ].join(' · '),
            style: small,
          ),
          const SizedBox(height: 12),
          for (final (k, v) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(child: Text(k)),
                  Text(v),
                ],
              ),
            ),
        ] else
          Text(switch (s.kind) {
            SpaceKind.start => 'Collect ${money(LandlordBoard.salary)} when you pass or land here.',
            SpaceKind.tax => 'Pay ${money(s.tax)} into the Rest Stop pot.',
            SpaceKind.card => 'Draw a ${s.deck!.title} card.',
            SpaceKind.jail => 'Just visiting, unless you were sent here.',
            SpaceKind.rest =>
              'Land here to collect the tax, bail and card payments paid so far. '
                  '${board.pot > 0 ? 'The pot holds ${money(board.pot)}.' : 'The pot is empty.'}',
            SpaceKind.goToJail => 'Go straight to jail without collecting ${money(LandlordBoard.salary)}.',
            _ => '',
          }, style: small),
        if (actions.isNotEmpty) ...[const SizedBox(height: 16), Wrap(spacing: 8, runSpacing: 8, children: actions)],
      ],
    );
  }
}

/// Both players' properties and cash. Each of mine shows what it can raise
/// (a building's sale, or its mortgage value) with a button to do it there,
/// when [canAct]; the list keeps up as cash comes in.
Future<void> showPropertiesSheet(
  BuildContext context,
  LandlordBoard b,
  Side me,
  (String, String) names,
  bool Function(Map<String, Object?> move) legal,
  void Function(Map<String, Object?> move) onPlay, {
  bool canAct = false,
}) {
  var cur = b;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheet) {
        final theme = Theme.of(context);
        final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);

        /// The quickest way space [i] raises cash now, if any: sell a
        /// building, else mortgage it.
        (String, Map<String, Object?>)? raise(int i) {
          if (cur.owner(i) != me) return null;
          final sell = {'a': 'sell', 'space': i};
          final mortgage = {'a': 'mortgage', 'space': i};
          final next = cur.play(sell) as LandlordBoard?;
          if (next != null) return ('Sell +${money(next.cash(me) - cur.cash(me))}', sell);
          if (!cur.isMortgaged(i)) return ('Mortgage +${money(landlordSpaces[i].mortgageValue)}', mortgage);
          return null;
        }

        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.7,
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                for (final p in [me, me.other]) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      '${_owner(names, p)} · ${money(cur.cash(p))}'
                      '${cur.heldCards(p).isEmpty ? '' : ' · ${cur.heldCards(p).length} jail-free card${cur.heldCards(p).length == 1 ? '' : 's'}'}',
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  for (var i = 0; i < 40; i++)
                    if (cur.owner(i) == p)
                      ListTile(
                        key: ValueKey('owned-$i'),
                        dense: true,
                        leading: Container(width: 12, height: 24, color: landlordSpaces[i].group!.color),
                        title: Text(landlordSpaces[i].name),
                        subtitle: Text(
                          [
                            if (cur.level(i) == 5) 'Hotel' else if (cur.level(i) > 0) '${cur.level(i)} houses',
                            if (cur.isMortgaged(i))
                              'Mortgaged'
                            else
                              'Mortgage value ${money(landlordSpaces[i].mortgageValue)}',
                          ].join(' · '),
                          style: small,
                        ),
                        trailing: switch (canAct && p == me ? raise(i) : null) {
                          (final label, final move) when cur.play(move) != null => TextButton(
                            key: ValueKey('raise-$i'),
                            onPressed: () {
                              onPlay(move);
                              setSheet(() => cur = cur.play(move)! as LandlordBoard);
                            },
                            child: Text(label),
                          ),
                          _ => null,
                        },
                        onTap: () {
                          Navigator.pop(context);
                          showSpaceSheet(context, cur, i, me, names, legal, onPlay);
                        },
                      ),
                  if (!Iterable.generate(40).any((i) => cur.owner(i) == p))
                    const ListTile(dense: true, title: Text('No properties yet')),
                ],
              ],
            ),
          ),
        );
      },
    ),
  );
}
