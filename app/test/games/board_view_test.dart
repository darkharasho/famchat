import 'dart:math' as math;

import 'package:famchat/games/checkers.dart';
import 'package:famchat/games/chess_board.dart';
import 'package:famchat/games/dots_and_boxes.dart';
import 'package:famchat/games/four_in_a_row.dart';
import 'package:famchat/games/go_fish.dart';
import 'package:famchat/games/reversi.dart';
import 'package:famchat/games/rules.dart';
import 'package:famchat/games/widgets/board_view.dart';
import 'package:famchat/games/widgets/checkers_view.dart';
import 'package:famchat/games/widgets/chess_view.dart';
import 'package:famchat/games/widgets/go_fish_view.dart';
import 'package:famchat/games/widgets/reversi_view.dart';
import 'package:famchat/theme/app_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// The Go Fish card of [rank] (1..13) and [suit] (0..3).
int _c(int rank, int suit) => (rank - 1) * 4 + suit;

GoFishEvent _ev({
  required Side asker,
  required int rank,
  int given = 0,
  int? drawn,
  bool again = false,
  List<(Side, int)> booked = const [],
}) => GoFishEvent(asker, rank, given, drawn, again, booked);

/// Any Go Fish card face (`card-<n>` key).
final _anyCardFace = find.byWidgetPredicate(
  (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('card-'),
);

const _fm = CheckersSquare(Side.first, CheckersPiece.man);
const _sm = CheckersSquare(Side.second, CheckersPiece.man);

/// Built once, so a rebuilt host doesn't animate between equal themes.
final _lightTheme = buildTheme(Brightness.light);

Widget host(Widget child) => MaterialApp(
  theme: _lightTheme,
  home: Scaffold(
    body: Center(child: SizedBox(width: 400, height: 400, child: child)),
  ),
);

void main() {
  late List<Map<String, Object?>> played;
  setUp(() => played = []);

  Widget view(
    Board board, {
    Side? mySide = Side.first,
    bool enabled = true,
    bool thumbnail = false,
    (String, String)? initials,
    (String, String)? names,
  }) => host(
    BoardView(
      board: board,
      mySide: mySide,
      onPlay: played.add,
      enabled: enabled,
      thumbnail: thumbnail,
      initials: initials,
      names: names,
    ),
  );

  group('Go Fish', () {
    const you = Side.first, mom = Side.second;
    const names = ('You', 'Mom');

    test('rank names', () {
      expect(rankName(1), 'Ace');
      expect(rankName(7), '7');
      expect(rankName(13), 'King');
      expect(rankName(1, plural: true), 'Aces');
      expect(rankName(10, plural: true), '10s');
      expect(rankName(11, plural: true), 'Jacks');
      expect(rankName(12, plural: true), 'Queens');
    });

    test('log lines', () {
      expect(goFishLog(_ev(asker: mom, rank: 7, given: 2), you, names), 'Mom asked for 7s — you gave 2');
      expect(goFishLog(_ev(asker: you, rank: 7, given: 1, again: true), you, names), 'You asked for 7s — Mom gave 1');
      expect(
        goFishLog(_ev(asker: you, rank: 13, drawn: _c(4, 0)), you, names),
        'You asked for Kings — Go fish. You drew a 4',
      );
      expect(goFishLog(_ev(asker: mom, rank: 13, drawn: _c(4, 0)), you, names), 'Mom asked for Kings — Go fish');
      expect(
        goFishLog(_ev(asker: mom, rank: 13, drawn: _c(13, 1), again: true), you, names),
        'Mom asked for Kings — Go fish. Mom drew a King and goes again',
      );
      expect(
        goFishLog(_ev(asker: you, rank: 1, drawn: _c(1, 1), again: true), you, names),
        'You asked for Aces — Go fish. You drew an Ace and go again',
      );
      expect(goFishLog(_ev(asker: you, rank: 5), you, names), 'You asked for 5s — Go fish');
      expect(
        goFishLog(_ev(asker: mom, rank: 5, given: 3, again: true, booked: [(mom, 5)]), you, names),
        'Mom asked for 5s — you gave 3. Mom made a book of 5s',
      );
    });

    final board = GoFishBoard.custom(
      firstHand: [_c(2, 0), _c(2, 1), _c(9, 3)],
      secondHand: [_c(5, 0), _c(12, 2), _c(13, 1)],
      stock: [_c(3, 0), _c(4, 0)],
      firstBooks: [7],
    );

    testWidgets('my hand shows; opponent cards never render', (tester) async {
      await tester.pumpWidget(view(board, names: names));
      for (final c in board.hand(you)) {
        expect(find.byKey(Key('card-$c')), findsOneWidget);
      }
      for (final c in [...board.hand(mom), _c(3, 0), _c(4, 0)]) {
        expect(find.byKey(Key('card-$c')), findsNothing);
      }
      expect(find.text('2 in the pond'), findsOneWidget);
      expect(find.text('3 cards'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a thumbnail and a spectator show no card faces', (tester) async {
      await tester.pumpWidget(view(board, thumbnail: true));
      expect(_anyCardFace, findsNothing);
      await tester.pumpWidget(view(board, mySide: null));
      expect(_anyCardFace, findsNothing);
    });

    testWidgets('tapping a rank I hold asks for it', (tester) async {
      await tester.pumpWidget(view(board, names: names));
      expect(find.byKey(const Key('rank-5')), findsNothing);
      await tester.tap(find.byKey(const Key('rank-2')));
      await tester.tap(find.byKey(const Key('rank-9')));
      expect(played, [
        {'rank': 2},
        {'rank': 9},
      ]);
    });

    testWidgets("ranks don't play when disabled or on the other player's turn", (tester) async {
      await tester.pumpWidget(view(board, enabled: false));
      await tester.tap(find.byKey(const Key('rank-2')));
      await tester.pumpWidget(view(board, mySide: mom));
      await tester.tap(find.byKey(const Key('rank-5')));
      expect(played, isEmpty);
    });

    testWidgets('the log shows the last asks in plain words', (tester) async {
      final asked = board.play({'rank': 9})! as GoFishBoard;
      await tester.pumpWidget(view(asked, names: names));
      expect(find.text('You asked for 9s — Go fish. You drew a 3'), findsOneWidget);
      await tester.pumpWidget(view(asked, mySide: mom, names: ('Dad', 'You')));
      expect(find.text('Dad asked for 9s — Go fish'), findsOneWidget);
    });

    testWidgets('an ask plays out: bubble, Go fish, then the card lands', (tester) async {
      final asked = board.play({'rank': 9})! as GoFishBoard;
      final drawn = asked.events.last.drawn!;
      await tester.pumpWidget(view(board, names: names));
      await tester.pumpWidget(view(asked, names: names));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Got any 9s?'), findsOneWidget);
      expect(find.byKey(Key('card-$drawn')), findsNothing, reason: 'not drawn yet');
      expect(find.text('2 in the pond'), findsOneWidget);
      await tester.tap(find.byKey(const Key('rank-2')));
      await tester.pump(const Duration(milliseconds: 1500));
      expect(find.text('Go fish!'), findsNWidgets(2), reason: 'the reply and the splash');
      await tester.pumpAndSettle();
      expect(find.text('Got any 9s?'), findsNothing);
      expect(find.text('Go fish!'), findsNothing);
      expect(find.byKey(Key('card-$drawn')), findsOneWidget);
      expect(find.text('1 in the pond'), findsOneWidget);
      expect(played, isEmpty, reason: 'ranks are off while an ask plays out');
      expect(tester.takeException(), isNull);
    });

    testWidgets("the opponent's ask: they ask, I hand cards over", (tester) async {
      final mine = GoFishBoard.custom(
        firstHand: [_c(2, 0), _c(9, 3)],
        secondHand: [_c(9, 1), _c(4, 0)],
        stock: [_c(3, 0)],
        turn: mom,
      );
      final taken = mine.play({'rank': 9})! as GoFishBoard;
      await tester.pumpWidget(view(mine, names: names));
      await tester.pumpWidget(view(taken, names: names));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Got any 9s?'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1000));
      expect(find.text('Here you go'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byKey(Key('card-${_c(9, 3)}')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a book pops in with a splash', (tester) async {
      final near = GoFishBoard.custom(
        firstHand: [_c(5, 0), _c(5, 1), _c(5, 2), _c(2, 0)],
        secondHand: [_c(5, 3), _c(4, 0)],
        stock: [_c(3, 0)],
      );
      final booked = near.play({'rank': 5})! as GoFishBoard;
      await tester.pumpWidget(view(near, names: names));
      await tester.pumpWidget(view(booked, names: names));
      await tester.pump(const Duration(milliseconds: 2400));
      expect(find.text('Book of 5s!'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('book-5')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the move strip shows the last two; tap it for every move', (tester) async {
      var b = board;
      for (final r in [9, 2]) {
        b = b.play({'rank': r})! as GoFishBoard;
        if (b.toMove == mom) b = b.play({'rank': GoFishBoard.rankOf(b.hand(mom).first)})! as GoFishBoard;
      }
      await tester.pumpWidget(view(b, names: names));
      final lines = [for (final e in b.events) goFishLog(e, you, names)];
      expect(find.text(lines.last), findsOneWidget);
      expect(find.text(lines.first), lines.length > 2 ? findsNothing : findsOneWidget);
      await tester.tap(find.byKey(const Key('gofish-log')));
      await tester.pumpAndSettle();
      expect(find.text('Moves'), findsOneWidget);
      for (final l in lines) {
        expect(find.descendant(of: find.byKey(const Key('gofish-log-list')), matching: find.text(l)), findsOneWidget);
      }
    });

    test('new events: a few asks on from the same game', () {
      final one = board.play({'rank': 9})! as GoFishBoard;
      expect(goFishNewEvents(board, one), one.events);
      expect(goFishNewEvents(one, one), isEmpty);
      final two = one.play({'rank': GoFishBoard.rankOf(one.hand(one.toMove).first)})! as GoFishBoard;
      expect(goFishNewEvents(one, two), [two.events.last]);
      expect(goFishNewEvents(two, board), isEmpty, reason: 'a new deal');
    });

    test('score and aspect', () {
      expect(boardScore(board), (1, 0));
      expect(boardAspectRatio(board), 3 / 2);
    });
  });

  testWidgets('tapping an empty tic-tac-toe cell calls onPlay {cell: n}', (
    tester,
  ) async {
    await tester.pumpWidget(view(initialBoard(GameType.tictactoe)));
    await tester.tap(find.byKey(const Key('sq-4')));
    expect(played, [
      {'cell': 4},
    ]);
  });

  testWidgets('disabled board ignores taps', (tester) async {
    await tester.pumpWidget(
      view(initialBoard(GameType.tictactoe), enabled: false),
    );
    await tester.tap(find.byKey(const Key('sq-4')), warnIfMissed: false);
    // Not my turn: second cannot play on a fresh board.
    await tester.pumpWidget(
      view(initialBoard(GameType.tictactoe), mySide: Side.second),
    );
    await tester.tap(find.byKey(const Key('sq-0')), warnIfMissed: false);
    // Thumbnails and spectators never play.
    await tester.pumpWidget(
      view(initialBoard(GameType.tictactoe), thumbnail: true),
    );
    await tester.tap(find.byKey(const Key('sq-1')), warnIfMissed: false);
    await tester.pumpWidget(
      view(initialBoard(GameType.tictactoe), mySide: null),
    );
    await tester.tap(find.byKey(const Key('sq-2')), warnIfMissed: false);
    expect(played, isEmpty);
  });

  testWidgets('checkers: tapping a piece then a target sends the path; '
      'multi-jump sends only when complete', (tester) async {
    await tester.pumpWidget(view(initialBoard(GameType.checkers)));
    await tester.tap(find.byKey(const Key('sq-9')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sq-13')));
    expect(played, [
      {
        'path': [9, 13],
      },
    ]);

    played.clear();
    // 4 jumps 9 to 13, then 18 to 22.
    final board = CheckersBoard.custom({
      4: _fm,
      9: _sm,
      18: _sm,
      31: _sm,
    }, Side.first);
    expect(board.legalPaths(), [
      [4, 13, 22],
    ]);
    await tester.pumpWidget(view(board));
    await tester.tap(find.byKey(const Key('sq-4')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sq-13')));
    await tester.pump();
    expect(played, isEmpty);
    await tester.tap(find.byKey(const Key('sq-22')));
    expect(played, [
      {
        'path': [4, 13, 22],
      },
    ]);
  });

  testWidgets('chess: e2 then e4 sends {uci: e2e4}', (tester) async {
    await tester.pumpWidget(view(initialBoard(GameType.chess)));
    await tester.tap(find.byKey(const Key('sq-e2')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sq-e4')));
    expect(played, [
      {'uci': 'e2e4'},
    ]);
  });

  testWidgets('promotion picker sends a7a8q', (tester) async {
    await tester.pumpWidget(
      view(ChessBoard.fromFen('8/P7/8/8/8/8/8/k6K w - - 0 1')),
    );
    await tester.tap(find.byKey(const Key('sq-a7')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sq-a8')));
    await tester.pump();
    expect(played, isEmpty);
    expect(find.byKey(const Key('promo-n')), findsOneWidget);
    await tester.tap(find.byKey(const Key('promo-q')));
    expect(played, [
      {'uci': 'a7a8q'},
    ]);
  });

  testWidgets('second side sees the board flipped (sq-31 at bottom-left)', (
    tester,
  ) async {
    Future<void> expectBottomLeft(String key, Iterable<String> all) async {
      final c = tester.getCenter(find.byKey(Key(key)));
      for (final k in all) {
        final o = tester.getCenter(find.byKey(Key(k)));
        expect(c.dy, greaterThanOrEqualTo(o.dy), reason: '$key vs $k');
        expect(c.dx, lessThanOrEqualTo(o.dx), reason: '$key vs $k');
      }
    }

    final checkers = [for (var i = 0; i < 32; i++) 'sq-$i'];
    await tester.pumpWidget(
      view(initialBoard(GameType.checkers), mySide: Side.second),
    );
    await expectBottomLeft('sq-31', checkers);
    await tester.pumpWidget(view(initialBoard(GameType.checkers)));
    await expectBottomLeft('sq-0', checkers);
    await tester.pumpWidget(
      view(initialBoard(GameType.checkers), mySide: null),
    );
    await expectBottomLeft('sq-0', checkers);

    final chess = [
      for (final f in 'abcdefgh'.split(''))
        for (var r = 1; r <= 8; r++) 'sq-$f$r',
    ];
    await tester.pumpWidget(
      view(initialBoard(GameType.chess), mySide: Side.second),
    );
    await expectBottomLeft('sq-h8', chess);
    await tester.pumpWidget(view(initialBoard(GameType.chess)));
    await expectBottomLeft('sq-a1', chess);
  });

  testWidgets('selection resets when the position changes', (tester) async {
    final start = initialBoard(GameType.chess);
    await tester.pumpWidget(view(start));
    await tester.tap(find.byKey(const Key('sq-g1')));
    await tester.pump();
    final next = start.play({'uci': 'e2e4'})!.play({'uci': 'e7e5'})!;
    await tester.pumpWidget(view(next));
    await tester.tap(find.byKey(const Key('sq-f3')));
    expect(played, isEmpty);
    // Selecting again still works.
    await tester.tap(find.byKey(const Key('sq-g1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sq-f3')));
    expect(played, [
      {'uci': 'g1f3'},
    ]);
  });

  testWidgets('selection survives a rebuild with an equal position', (
    tester,
  ) async {
    // Each replay of the same moves makes a new Board instance, as
    // gamesProvider does whenever the chat's messages change.
    Board chess() =>
        initialBoard(GameType.chess)
            .play({'uci': 'e2e4'})!
            .play({'uci': 'e7e5'})!;
    await tester.pumpWidget(view(chess()));
    await tester.tap(find.byKey(const Key('sq-g1')));
    await tester.pump();
    await tester.pumpWidget(view(chess()));
    await tester.tap(find.byKey(const Key('sq-f3')));
    expect(played, [
      {'uci': 'g1f3'},
    ]);

    played.clear();
    Board checkers() => initialBoard(GameType.checkers)
        .play({
          'path': [9, 13],
        })!
        .play({
          'path': [23, 19],
        })!;
    await tester.pumpWidget(view(checkers()));
    await tester.tap(find.byKey(const Key('sq-10')));
    await tester.pump();
    await tester.pumpWidget(view(checkers()));
    await tester.tap(find.byKey(const Key('sq-14')));
    expect(played, [
      {
        'path': [10, 14],
      },
    ]);
  });

  testWidgets('promotion picker fits a small board; its padding does not '
      'cancel', (tester) async {
    await tester.pumpWidget(
      host(
        Center(
          child: SizedBox.square(
            dimension: 160,
            child: BoardView(
              board: ChessBoard.fromFen('8/P7/8/8/8/8/8/k6K w - - 0 1'),
              mySide: Side.first,
              onPlay: played.add,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('sq-a7')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sq-a8')));
    await tester.pump();
    expect(tester.takeException(), isNull);
    final picker = find.byKey(const Key('promo-picker'));
    final box = tester.getRect(picker);
    expect(box.width, lessThanOrEqualTo(160));
    // A tap on the picker's own padding keeps it open.
    await tester.tapAt(box.topLeft + const Offset(2, 2));
    await tester.pump();
    expect(picker, findsOneWidget);
    await tester.tap(find.byKey(const Key('promo-r')));
    expect(played, [
      {'uci': 'a7a8r'},
    ]);
  });

  testWidgets('thumbnail renders all games without labels', (tester) async {
    for (final t in GameType.values) {
      await tester.pumpWidget(view(initialBoard(t), thumbnail: true));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('four in a row: tapping a column sends {col: n}', (tester) async {
    await tester.pumpWidget(view(initialBoard(GameType.fourinarow)));
    await tester.tap(find.byKey(const Key('col-4')));
    expect(played, [
      {'col': 4},
    ]);
  });

  testWidgets('four in a row: tapping a full column does nothing', (
    tester,
  ) async {
    var b = initialBoard(GameType.fourinarow);
    for (var i = 0; i < 6; i++) {
      b = b.play({'col': 0})!;
    }
    await tester.pumpWidget(view(b));
    await tester.tap(find.byKey(const Key('col-0')));
    expect(played, isEmpty);
    await tester.tap(find.byKey(const Key('col-1')));
    expect(played, [
      {'col': 1},
    ]);
  });

  testWidgets('four in a row: disabled, spectator and thumbnail ignore taps', (
    tester,
  ) async {
    final b = initialBoard(GameType.fourinarow);
    await tester.pumpWidget(view(b, enabled: false));
    await tester.tap(find.byKey(const Key('col-2')), warnIfMissed: false);
    await tester.pumpWidget(view(b, mySide: Side.second));
    await tester.tap(find.byKey(const Key('col-2')), warnIfMissed: false);
    await tester.pumpWidget(view(b, mySide: null));
    await tester.tap(find.byKey(const Key('col-2')), warnIfMissed: false);
    await tester.pumpWidget(view(b, thumbnail: true));
    await tester.tap(find.byKey(const Key('col-2')), warnIfMissed: false);
    expect(played, isEmpty);
  });

  testWidgets('four in a row: a tap in the gap between columns drops a disc', (
    tester,
  ) async {
    await tester.pumpWidget(view(initialBoard(GameType.fourinarow)));
    // Just right of column 2's last cell: the gap belongs to column 3.
    final left = tester.getRect(find.byKey(const Key('sq-37')));
    final right = tester.getRect(find.byKey(const Key('sq-38')));
    expect(right.left, greaterThan(left.right));
    await tester.tapAt(Offset((left.right + right.left) / 2, left.center.dy));
    expect(played, [
      {'col': 3},
    ]);
  });

  testWidgets('four in a row: the winning four are ringed', (tester) async {
    // First plays 0..3 on the bottom row, second stacks on 0..2.
    var b = initialBoard(GameType.fourinarow);
    for (final c in [0, 0, 1, 1, 2, 2, 3]) {
      b = b.play({'col': c})!;
    }
    expect((b as FourInARowBoard).winningLine, isNotNull);
    await tester.pumpWidget(view(b));
    bool ringed(int sq) => tester
        .widgetList<DecoratedBox>(
          find.descendant(
            of: find.byKey(Key('sq-$sq')),
            matching: find.byType(DecoratedBox),
          ),
        )
        .any((d) {
          final dec = d.decoration;
          return dec is BoxDecoration &&
              dec.shape == BoxShape.circle &&
              dec.border != null;
        });
    // Bottom row is display row 5: sq-35..38 win; the discs above don't.
    for (final sq in [35, 36, 37, 38]) {
      expect(ringed(sq), isTrue, reason: 'sq-$sq');
    }
    for (final sq in [28, 29, 30]) {
      expect(ringed(sq), isFalse, reason: 'sq-$sq');
    }
  });

  testWidgets('four in a row: names each player\'s colour, mine first; '
      'columns say how full they are', (tester) async {
    final semantics = tester.ensureSemantics();
    final b = initialBoard(GameType.fourinarow).play({'col': 2})!;
    await tester.pumpWidget(
      view(b, mySide: Side.second, names: ('Mom', 'You')),
    );
    expect(find.bySemanticsLabel('You: yellow discs'), findsOneWidget);
    expect(find.bySemanticsLabel('Mom: red discs'), findsOneWidget);
    expect(
      tester.getCenter(find.byKey(const Key('name-second'))).dx,
      lessThan(tester.getCenter(find.byKey(const Key('name-first'))).dx),
    );
    expect(find.bySemanticsLabel('column 3, 5 free'), findsOneWidget);
    expect(find.bySemanticsLabel('column 1, 6 free'), findsOneWidget);
    await tester.pumpWidget(view(b, thumbnail: true, names: ('Mom', 'You')));
    expect(find.text('You'), findsNothing);
    semantics.dispose();
  });

  testWidgets('reversi: tapping a legal cell sends {cell: n}', (tester) async {
    await tester.pumpWidget(view(initialBoard(GameType.reversi)));
    await tester.tap(find.byKey(const Key('sq-29')));
    expect(played, [
      {'cell': 29},
    ]);
  });

  testWidgets('reversi: tapping an illegal cell does nothing', (tester) async {
    await tester.pumpWidget(view(initialBoard(GameType.reversi)));
    await tester.tap(find.byKey(const Key('sq-0')));
    await tester.tap(find.byKey(const Key('sq-27')));
    expect(played, isEmpty);
  });

  testWidgets('reversi: shows both counts; thumbnail, spectator and '
      'disabled ignore taps', (tester) async {
    final b = initialBoard(GameType.reversi);
    await tester.pumpWidget(view(b));
    expect(find.byKey(const Key('count-first')), findsOneWidget);
    expect(find.byKey(const Key('count-second')), findsOneWidget);
    await tester.pumpWidget(view(b, enabled: false));
    await tester.tap(find.byKey(const Key('sq-29')), warnIfMissed: false);
    await tester.pumpWidget(view(b, mySide: Side.second));
    await tester.tap(find.byKey(const Key('sq-29')), warnIfMissed: false);
    await tester.pumpWidget(view(b, mySide: null));
    await tester.tap(find.byKey(const Key('sq-29')), warnIfMissed: false);
    await tester.pumpWidget(view(b, thumbnail: true));
    expect(find.byKey(const Key('count-first')), findsNothing);
    await tester.tap(find.byKey(const Key('sq-29')), warnIfMissed: false);
    expect(played, isEmpty);
  });

  testWidgets('reversi: scores are labelled with names, mine first; '
      'cells say what is on them', (tester) async {
    final semantics = tester.ensureSemantics();
    final b = ReversiBoard.initial().play({'cell': 29})!;
    await tester.pumpWidget(
      view(b, mySide: Side.second, names: ('Mom', 'You')),
    );
    expect(find.bySemanticsLabel('You: 1 light disc'), findsOneWidget);
    expect(find.bySemanticsLabel('Mom: 4 dark discs'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    expect(
      tester.getCenter(find.byKey(const Key('count-second'))).dx,
      lessThan(tester.getCenter(find.byKey(const Key('count-first'))).dx),
    );
    // 27 is d5 and 35 d4 (row 0 is rank 8).
    expect(find.bySemanticsLabel('d5, dark disc'), findsOneWidget);
    expect(find.bySemanticsLabel('d4, light disc'), findsOneWidget);
    expect(find.bySemanticsLabel('a8, empty'), findsOneWidget);
    expect(ReversiView.cellName(56), 'a1');
    semantics.dispose();
  });

  testWidgets('reversi: both disc colours contrast with the squares', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      late (Color, Color) surface;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(brightness),
          home: Builder(
            builder: (context) {
              surface = ReversiView.surface(context);
              return const SizedBox();
            },
          ),
        ),
      );
      double contrast(Color a, Color b) {
        final x = a.computeLuminance(), y = b.computeLuminance();
        return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
      }

      for (final side in Side.values) {
        expect(
          contrast(ReversiView.discColor(side), surface.$1),
          greaterThan(2.5),
          reason: '$brightness $side',
        );
      }
    }
  });

  testWidgets('dots and boxes: tapping a line sends {line: n}', (tester) async {
    await tester.pumpWidget(view(initialBoard(GameType.dotsandboxes)));
    for (final n in [0, 19, 20, 39, 26]) {
      await tester.tap(find.byKey(Key('line-$n')));
    }
    expect(played, [
      {'line': 0},
      {'line': 19},
      {'line': 20},
      {'line': 39},
      {'line': 26},
    ]);
  });

  testWidgets('dots and boxes: a drawn line can\'t be tapped', (tester) async {
    final b = initialBoard(GameType.dotsandboxes)
        .play({'line': 5})!
        .play({'line': 9})!;
    // First to move again.
    await tester.pumpWidget(view(b));
    await tester.tap(find.byKey(const Key('line-5')), warnIfMissed: false);
    await tester.tap(find.byKey(const Key('line-9')), warnIfMissed: false);
    expect(played, isEmpty);
    await tester.tap(find.byKey(const Key('line-6')));
    expect(played, [
      {'line': 6},
    ]);
  });

  testWidgets('dots and boxes: claimed boxes show initials and scores; '
      'thumbnail, spectator and disabled ignore taps', (tester) async {
    final b = DotsAndBoxesBoard.custom(
      {0, 4, 20, 21},
      {0: Side.second},
      Side.second,
    );
    await tester.pumpWidget(view(b, mySide: Side.second, initials: ('M', 'D')));
    expect(find.text('D'), findsOneWidget);
    expect(find.text('M'), findsNothing);
    expect(find.byKey(const Key('count-second')), findsOneWidget);
    await tester.pumpWidget(view(b, mySide: Side.second));
    expect(find.text('D'), findsNothing);
    await tester.pumpWidget(
      view(b, mySide: Side.second, thumbnail: true, initials: ('M', 'D')),
    );
    expect(find.text('D'), findsNothing);
    expect(find.byKey(const Key('count-second')), findsNothing);
    await tester.tap(find.byKey(const Key('line-1')), warnIfMissed: false);
    await tester.pumpWidget(view(b, mySide: Side.first));
    await tester.tap(find.byKey(const Key('line-1')), warnIfMissed: false);
    await tester.pumpWidget(view(b, mySide: null));
    await tester.tap(find.byKey(const Key('line-1')), warnIfMissed: false);
    await tester.pumpWidget(view(b, mySide: Side.second, enabled: false));
    await tester.tap(find.byKey(const Key('line-1')), warnIfMissed: false);
    expect(played, isEmpty);
  });

  testWidgets('dots and boxes: scores are labelled with names; lines say '
      'which edge they are and whether drawn', (tester) async {
    final semantics = tester.ensureSemantics();
    final b = DotsAndBoxesBoard.custom(
      {0, 4, 20, 21},
      {0: Side.second},
      Side.second,
    );
    await tester.pumpWidget(view(b, mySide: Side.first, names: ('You', 'Dad')));
    expect(find.bySemanticsLabel('You: 0 boxes, red'), findsOneWidget);
    expect(find.bySemanticsLabel('Dad: 1 box, blue'), findsOneWidget);
    expect(find.bySemanticsLabel('top edge of box 1, drawn'), findsOneWidget);
    expect(
      find.bySemanticsLabel('top edge of box 2, not drawn'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('bottom edge of box 16, not drawn'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('left edge of box 2, drawn'), findsOneWidget);
    expect(
      find.bySemanticsLabel('right edge of box 16, not drawn'),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('dots and boxes: a tap inside a box picks its nearest side', (
    tester,
  ) async {
    await tester.pumpWidget(view(initialBoard(GameType.dotsandboxes)));
    final r = tester.getRect(find.byKey(const Key('line-0')));
    // Below the top line's midpoint, inside box 0: still line 0.
    await tester.tapAt(r.center + Offset(0, r.height * 0.3));
    // Towards box 0's right side: line 21.
    await tester.tapAt(r.center + Offset(r.width * 0.3, r.height * 0.3));
    expect(played, [
      {'line': 0},
      {'line': 21},
    ]);
  });

  testWidgets('dots and boxes renders in dark mode', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 300,
            child: BoardView(
              board: initialBoard(GameType.dotsandboxes).play({'line': 3})!,
              mySide: Side.second,
              onPlay: played.add,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('line-38')));
    expect(played, [
      {'line': 38},
    ]);
  });

  group('moves play out', () {
    Widget reduced(Widget child) => MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: child,
    );

    Board oneMove(GameType t) {
      final b = initialBoard(t);
      return switch (b) {
        ReversiBoard() => b.play({'cell': b.legalCells().first})!,
        CheckersBoard() => b.play({'path': b.legalPaths().first})!,
        ChessBoard() => b.play({'uci': 'e2e4'})!,
        DotsAndBoxesBoard() => b.play({'line': 0})!,
        FourInARowBoard() => b.play({'col': 3})!,
        _ => b.play({'cell': 4})!,
      };
    }

    for (final t in [
      GameType.tictactoe,
      GameType.fourinarow,
      GameType.reversi,
      GameType.dotsandboxes,
      GameType.checkers,
      GameType.chess,
    ]) {
      testWidgets('${t.name}: one move animates, then settles', (tester) async {
        await tester.pumpWidget(view(initialBoard(t)));
        expect(tester.hasRunningAnimations, isFalse, reason: 'opening is still');
        await tester.pumpWidget(view(oneMove(t)));
        await tester.pump(const Duration(milliseconds: 40));
        expect(tester.hasRunningAnimations, isTrue);
        await tester.pumpAndSettle();
        expect(tester.hasRunningAnimations, isFalse);
      });

      testWidgets('${t.name}: reduced motion shows the move at once', (
        tester,
      ) async {
        await tester.pumpWidget(reduced(view(initialBoard(t))));
        await tester.pumpWidget(reduced(view(oneMove(t))));
        await tester.pump();
        expect(tester.hasRunningAnimations, isFalse);
      });

      testWidgets('${t.name}: thumbnails never animate', (tester) async {
        await tester.pumpWidget(view(initialBoard(t), thumbnail: true));
        await tester.pumpWidget(view(oneMove(t), thumbnail: true));
        await tester.pump();
        expect(tester.hasRunningAnimations, isFalse);
      });
    }

    testWidgets('chess: the piece slides over, then sits on its square', (
      tester,
    ) async {
      final glyphOn = find.descendant(
        of: find.byKey(const Key('sq-e4')),
        matching: find.byType(ChessGlyph),
      );
      await tester.pumpWidget(view(initialBoard(GameType.chess)));
      await tester.pumpWidget(view(oneMove(GameType.chess)));
      await tester.pump(const Duration(milliseconds: 120));
      expect(glyphOn, findsNothing, reason: 'still on its way');
      expect(find.byType(ChessGlyph), findsNWidgets(32));
      await tester.pumpAndSettle();
      expect(glyphOn, findsOneWidget);
    });

    testWidgets('chess: two moves at once just show the position', (
      tester,
    ) async {
      final start = initialBoard(GameType.chess);
      final two = start.play({'uci': 'e2e4'})!.play({'uci': 'e7e5'})!;
      await tester.pumpWidget(view(start));
      await tester.pumpWidget(view(two));
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('checkers: a jumped piece stays until the mover passes', (
      tester,
    ) async {
      final b = CheckersBoard.custom({9: _fm, 13: _sm}, Side.first);
      final path = b.legalPaths().single;
      final after = b.play({'path': path})! as CheckersBoard;
      final gone = [
        for (var sq = 0; sq < 32; sq++)
          if (b.at(sq) != null && after.at(sq) == null && sq != path.first) sq,
      ].single;
      Finder discOn(int sq) => find.descendant(
        of: find.byKey(Key('sq-$sq')),
        matching: find.byType(CheckersDisc),
      );
      await tester.pumpWidget(view(b));
      await tester.pumpWidget(view(after));
      await tester.pump(const Duration(milliseconds: 30));
      expect(discOn(gone), findsOneWidget);
      expect(discOn(path.last), findsNothing);
      await tester.pumpAndSettle();
      expect(discOn(gone), findsNothing);
      expect(discOn(path.last), findsOneWidget);
    });

    testWidgets("taps wait for the move to finish", (tester) async {
      final b = oneMove(GameType.fourinarow);
      await tester.pumpWidget(view(initialBoard(GameType.fourinarow)));
      await tester.pumpWidget(view(b, mySide: Side.second));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(find.byKey(const Key('col-0')), warnIfMissed: false);
      expect(played, isEmpty);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('col-0')));
      expect(played, [
        {'col': 0},
      ]);
    });
  });

  group('checkers: a capture is due', () {
    // First (me) can jump 9 over 13; 0 can't move this turn.
    final due = CheckersBoard.custom({9: _fm, 13: _sm, 0: _fm}, Side.first);

    Color? outlineOf(WidgetTester tester, int sq) {
      for (final d in tester.widgetList<DecoratedBox>(
        find.descendant(of: find.byKey(Key('sq-$sq')), matching: find.byType(DecoratedBox)),
      )) {
        final dec = d.decoration;
        if (dec is BoxDecoration && dec.border != null && dec.shape == BoxShape.rectangle) {
          return (dec.border! as Border).top.color;
        }
      }
      return null;
    }

    testWidgets('the piece that can jump is marked; others are not', (tester) async {
      await tester.pumpWidget(view(due));
      expect(outlineOf(tester, 9), isNotNull);
      expect(outlineOf(tester, 0), isNull);
    });

    testWidgets('tapping a piece that can\'t move says you have to jump', (tester) async {
      await tester.pumpWidget(view(due));
      expect(find.text('You have to jump'), findsNothing);
      await tester.tap(find.byKey(const Key('sq-0')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('You have to jump'), findsOneWidget);
      expect(played, isEmpty);
      await tester.pumpAndSettle();
      // The jump still plays.
      await tester.tap(find.byKey(const Key('sq-9')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('sq-18')));
      expect(played, [
        {'path': [9, 18]},
      ]);
    });

    testWidgets('with optional jumps nothing is marked and steps play', (tester) async {
      final free = CheckersBoard.custom({9: _fm, 13: _sm, 0: _fm}, Side.first, optionalJumps: true);
      await tester.pumpWidget(view(free));
      expect(outlineOf(tester, 9), isNull);
      await tester.tap(find.byKey(const Key('sq-0')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('sq-4')));
      expect(played, [
        {'path': [0, 4]},
      ]);
      expect(find.text('You have to jump'), findsNothing);
    });
  });
}
