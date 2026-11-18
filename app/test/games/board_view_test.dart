import 'package:famchat/games/checkers.dart';
import 'package:famchat/games/chess_board.dart';
import 'package:famchat/games/dots_and_boxes.dart';
import 'package:famchat/games/rules.dart';
import 'package:famchat/games/widgets/board_view.dart';
import 'package:famchat/theme/app_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _fm = CheckersSquare(Side.first, CheckersPiece.man);
const _sm = CheckersSquare(Side.second, CheckersPiece.man);

Widget host(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.light),
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
  }) => host(
    BoardView(
      board: board,
      mySide: mySide,
      onPlay: played.add,
      enabled: enabled,
      thumbnail: thumbnail,
      initials: initials,
    ),
  );

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
    Board chess() => initialBoard(
      GameType.chess,
    ).play({'uci': 'e2e4'})!.play({'uci': 'e7e5'})!;
    await tester.pumpWidget(view(chess()));
    await tester.tap(find.byKey(const Key('sq-g1')));
    await tester.pump();
    await tester.pumpWidget(view(chess()));
    await tester.tap(find.byKey(const Key('sq-f3')));
    expect(played, [
      {'uci': 'g1f3'},
    ]);

    played.clear();
    Board checkers() => initialBoard(GameType.checkers).play({
      'path': [9, 13],
    })!.play({
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

  testWidgets('thumbnail renders all three games without labels', (
    tester,
  ) async {
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
}
