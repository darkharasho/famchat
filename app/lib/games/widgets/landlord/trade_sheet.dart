import 'package:material_ui/material_ui.dart';

import '../../landlord/landlord.dart';
import '../../rules.dart';
import 'landlord_log.dart';

/// Composes a trade offer from [me]: spaces, cash and jail-free cards on each
/// side. Send stays off until the board would accept the offer.
Future<void> showTradeSheet(
  BuildContext context,
  LandlordBoard b,
  Side me,
  (String, String) names,
  void Function(Map<String, Object?> move) onPlay,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: TradeComposer(board: b, me: me, names: names, onPlay: onPlay),
    ),
  );
}

class TradeComposer extends StatefulWidget {
  const TradeComposer({
    super.key,
    required this.board,
    required this.me,
    required this.names,
    required this.onPlay,
  });

  final LandlordBoard board;
  final Side me;
  final (String, String) names;
  final void Function(Map<String, Object?> move) onPlay;

  @override
  State<TradeComposer> createState() => _TradeComposerState();
}

class _TradeComposerState extends State<TradeComposer> {
  final _give = <int>{}, _get = <int>{};
  int _giveCash = 0, _getCash = 0, _giveCards = 0, _getCards = 0;

  Map<String, Object?> get _offer => {
    'a': 'offer',
    'give': {'cash': _giveCash, 'spaces': _give.toList()..sort(), 'cards': _giveCards},
    'get': {'cash': _getCash, 'spaces': _get.toList()..sort(), 'cards': _getCards},
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = widget.board;
    final them = widget.me.other;
    final other = them == Side.first ? widget.names.$1 : widget.names.$2;
    final valid = b.play(_offer) != null;

    Widget column(String title, String prefix, Side owner, Set<int> picked, int cash, int cards,
        void Function(int) setCash, void Function(int) setCards) {
      final spaces = [for (var i = 0; i < 40; i++) if (b.owner(i) == owner) i];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          if (spaces.isEmpty) Text('No properties', style: theme.textTheme.bodySmall),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final i in spaces)
                FilterChip(
                  key: Key('$prefix-$i'),
                  avatar: CircleAvatar(backgroundColor: landlordSpaces[i].group!.color, radius: 6),
                  label: Text(landlordSpaces[i].name),
                  selected: picked.contains(i),
                  onSelected: (on) => setState(() => on ? picked.add(i) : picked.remove(i)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _Stepper(
            key: Key('$prefix-cash'),
            label: 'Cash ${money(cash)}',
            onMinus: cash > 0 ? () => setState(() => setCash(cash >= 10 ? cash - 10 : 0)) : null,
            onPlus: cash + 10 <= b.cash(owner) ? () => setState(() => setCash(cash + 10)) : null,
          ),
          if (b.heldCards(owner).isNotEmpty)
            _Stepper(
              key: Key('$prefix-cards'),
              label: 'Jail-free cards $cards',
              onMinus: cards > 0 ? () => setState(() => setCards(cards - 1)) : null,
              onPlus: cards < b.heldCards(owner).length ? () => setState(() => setCards(cards + 1)) : null,
            ),
        ],
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Offer a trade to $other', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          column('You give', 'give', widget.me, _give, _giveCash, _giveCards, (v) => _giveCash = v, (v) => _giveCards = v),
          const Divider(height: 24),
          column('You get', 'get', them, _get, _getCash, _getCards, (v) => _getCash = v, (v) => _getCards = v),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('trade-send'),
            onPressed: valid
                ? () {
                    widget.onPlay(_offer);
                    Navigator.pop(context);
                  }
                : null,
            child: const Text('Send offer'),
          ),
        ],
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({super.key, required this.label, this.onMinus, this.onPlus});

  final String label;
  final VoidCallback? onMinus, onPlus;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: Text(label)),
      IconButton(onPressed: onMinus, icon: const Icon(Icons.remove), tooltip: 'Less'),
      IconButton(onPressed: onPlus, icon: const Icon(Icons.add), tooltip: 'More'),
    ],
  );
}
