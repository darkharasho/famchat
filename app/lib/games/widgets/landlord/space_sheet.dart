import 'package:material_ui/material_ui.dart';

import '../../landlord/landlord.dart';
import '../../rules.dart';
import 'landlord_log.dart';

String _owner((String, String) names, Side? s) =>
    s == null ? 'The bank' : (s == Side.first ? names.$1 : names.$2);

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
      if (s.kind == SpaceKind.utility) ...[
        ('One utility owned', '4× the dice'),
        ('Both owned', '10× the dice'),
      ],
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
              child: Row(children: [Expanded(child: Text(k)), Text(v)]),
            ),
        ] else
          Text(switch (s.kind) {
            SpaceKind.start => 'Collect ${money(LandlordBoard.salary)} when you pass or land here.',
            SpaceKind.tax => 'Pay ${money(s.tax)}.',
            SpaceKind.card => 'Draw a ${s.deck!.title} card.',
            SpaceKind.jail => 'Just visiting, unless you were sent here.',
            SpaceKind.rest => 'Nothing happens here.',
            SpaceKind.goToJail => 'Go straight to jail without collecting ${money(LandlordBoard.salary)}.',
            _ => '',
          }, style: small),
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: actions),
        ],
      ],
    );
  }
}

/// Both players' properties and jail-free cards; tap one for its card.
Future<void> showPropertiesSheet(
  BuildContext context,
  LandlordBoard b,
  Side me,
  (String, String) names,
  bool Function(Map<String, Object?> move) legal,
  void Function(Map<String, Object?> move) onPlay,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) {
      final theme = Theme.of(context);
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
                    '${_owner(names, p)} · ${money(b.cash(p))}'
                    '${b.heldCards(p).isEmpty ? '' : ' · ${b.heldCards(p).length} jail-free card${b.heldCards(p).length == 1 ? '' : 's'}'}',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                for (var i = 0; i < 40; i++)
                  if (b.owner(i) == p)
                    ListTile(
                      dense: true,
                      leading: Container(
                        width: 12,
                        height: 24,
                        color: landlordSpaces[i].group!.color,
                      ),
                      title: Text(landlordSpaces[i].name),
                      subtitle: Text(
                        [
                          if (b.level(i) == 5) 'Hotel' else if (b.level(i) > 0) '${b.level(i)} houses',
                          if (b.isMortgaged(i)) 'Mortgaged',
                        ].join(' · '),
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        showSpaceSheet(context, b, i, me, names, legal, onPlay);
                      },
                    ),
                if (!Iterable.generate(40).any((i) => b.owner(i) == p))
                  const ListTile(dense: true, title: Text('No properties yet')),
              ],
            ],
          ),
        ),
      );
    },
  );
}
