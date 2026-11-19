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
  final b = StringBuffer('$asker asked for ${rankName(e.rank, plural: true)} — ');
  final drawn = e.drawn;
  if (e.given > 0) {
    b.write('${other == 'You' ? 'you' : other} gave ${e.given}');
  } else {
    b.write('Go fish');
    if (drawn != null && e.again) {
      final r = GoFishBoard.rankOf(drawn);
      b.write('. $asker drew ${_a(r)} ${rankName(r)} and ${you ? 'go' : 'goes'} again');
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

/// Go Fish from [mySide]'s seat: the opponent's card backs and books on top,
/// the stock and the latest asks in the middle, my books and my hand (grouped
/// by rank; tap a rank to ask for it) at the bottom. The opponent's cards and
/// the stock are never drawn face up; spectators and thumbnails see no faces.
class GoFishView extends StatelessWidget {
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

  /// How many log lines show.
  static const logLines = 5;

  @override
  Widget build(BuildContext context) {
    if (thumbnail) return _Thumbnail(board: board);
    final theme = Theme.of(context);
    final me = mySide ?? Side.first;
    final them = me.other;
    final names = this.names ??
        (me == Side.first ? ('You', 'Opponent') : ('Opponent', 'You'));
    String name(Side s) => s == Side.first ? names.$1 : names.$2;
    final canPlay = interactive &&
        mySide != null &&
        board.outcome == null &&
        board.toMove == mySide;
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final log = board.events.length > logLines
        ? board.events.sublist(board.events.length - logLines)
        : board.events;

    return LayoutBuilder(
      builder: (context, box) {
        final cardW = (box.maxWidth / 9).clamp(30.0, 52.0);
        return Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PlayerRow(
                name: name(them),
                count: board.hand(them).length,
                books: board.books(them),
                cardW: cardW * 0.7,
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Column(
                      children: [
                        _CardBack(width: cardW),
                        const SizedBox(height: 4),
                        Text('${board.stockCount} in the stock', style: small),
                      ],
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ClipRect(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            for (final e in log)
                              Text(
                                goFishLog(e, me, names),
                                style: e == board.events.last
                                    ? theme.textTheme.bodySmall
                                    : small,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              _Books(label: name(me), books: board.books(me)),
              const SizedBox(height: 6),
              if (mySide == null)
                _PlayerRow(
                  name: name(me),
                  count: board.hand(me).length,
                  books: const [],
                  cardW: cardW * 0.7,
                )
              else
                _Hand(
                  cards: board.hand(me),
                  cardW: cardW,
                  canPlay: canPlay,
                  onAsk: (rank) => onPlay({'rank': rank}),
                ),
              if (canPlay)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Tap a rank to ask for it',
                    style: small,
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// A name, a fan of card backs with the count, and the books made.
class _PlayerRow extends StatelessWidget {
  const _PlayerRow({
    required this.name,
    required this.count,
    required this.books,
    required this.cardW,
  });

  final String name;
  final int count;
  final List<int> books;
  final double cardW;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = count.clamp(0, 10);
    return Row(
      children: [
        Text(name, style: theme.textTheme.titleSmall),
        const SizedBox(width: 8),
        SizedBox(
          width: shown == 0 ? 0 : cardW + (shown - 1) * cardW * 0.3,
          height: cardW * 1.4,
          child: Stack(
            children: [
              for (var i = 0; i < shown; i++)
                Positioned(left: i * cardW * 0.3, child: _CardBack(width: cardW)),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Text(
          count == 1 ? '1 card' : '$count cards',
          style: theme.textTheme.bodySmall,
        ),
        const Spacer(),
        Flexible(child: _Books(books: books)),
      ],
    );
  }
}

/// Books as rank chips ("Books: 7 K"), with an optional [label] before them.
class _Books extends StatelessWidget {
  const _Books({required this.books, this.label});

  final List<int> books;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = books.isEmpty
        ? 'No books'
        : 'Books: ${books.map((r) => _faces[r] ?? '$r').join(' ')}';
    return Text(
      label == null ? text : '$label · $text',
      style: theme.textTheme.bodySmall,
      overflow: TextOverflow.ellipsis,
      textAlign: label == null ? TextAlign.end : TextAlign.start,
    );
  }
}

/// My cards grouped by rank, each group a tap target `rank-<r>` (scrolls
/// sideways when wide).
class _Hand extends StatelessWidget {
  const _Hand({
    required this.cards,
    required this.cardW,
    required this.canPlay,
    required this.onAsk,
  });

  final List<int> cards;
  final double cardW;
  final bool canPlay;
  final void Function(int rank) onAsk;

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
      final fit = (box.maxWidth - 6 * g) / (g + 0.35 * extra);
      final w = g == 0 ? cardW : fit.clamp(26.0, cardW);
      return _row(groups, w);
    },
  );

  Widget _row(Map<int, List<int>> groups, double cardW) {
    final overlap = cardW * 0.35;
    return SizedBox(
      height: cardW * 1.4,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final MapEntry(key: rank, value: group) in groups.entries)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Semantics(
                  button: canPlay,
                  label: 'Ask for ${rankName(rank, plural: true)}',
                  child: GestureDetector(
                    key: Key('rank-$rank'),
                    behavior: HitTestBehavior.opaque,
                    onTap: canPlay ? () => onAsk(rank) : null,
                    child: SizedBox(
                      width: cardW + (group.length - 1) * overlap,
                      height: cardW * 1.4,
                      child: Stack(
                        children: [
                          for (var i = 0; i < group.length; i++)
                            Positioned(
                              left: i * overlap,
                              child: _CardFace(
                                key: Key('card-${group[i]}'),
                                card: group[i],
                                width: cardW,
                              ),
                            ),
                        ],
                      ),
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

class _CardFace extends StatelessWidget {
  const _CardFace({super.key, required this.card, required this.width});

  final int card;
  final double width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final suit = GoFishBoard.suitOf(card);
    final red = suit == 1 || suit == 2;
    final ink = red
        ? (dark ? const Color(0xFFFF6B7F) : const Color(0xFFD9363E))
        : scheme.onSurface;
    final rank = GoFishBoard.rankOf(card);
    return Container(
      width: width,
      height: width * 1.4,
      padding: EdgeInsets.all(width * 0.08),
      decoration: BoxDecoration(
        color: dark ? scheme.surfaceContainerHighest : const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(width * 0.12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: ink, height: 1, fontWeight: FontWeight.w600),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_faces[rank] ?? '$rank', style: TextStyle(fontSize: width * 0.32)),
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

class _CardBack extends StatelessWidget {
  const _CardBack({required this.width});

  final double width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: width * 1.4,
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(width * 0.12),
        border: Border.all(color: scheme.surface, width: 1.5),
      ),
      child: Center(
        child: Container(
          width: width * 0.55,
          height: width * 0.9,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(width * 0.08),
            border: Border.all(color: scheme.onPrimary.withValues(alpha: 0.5)),
          ),
        ),
      ),
    );
  }
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
                Text('${board.stockCount} left', style: theme.textTheme.bodySmall),
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
