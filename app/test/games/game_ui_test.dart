import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ImageFilter;

import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/games/rules.dart';
import 'package:famchat/games/widgets/board_view.dart';
import 'package:famchat/games/widgets/game_card.dart';
import 'package:famchat/games/widgets/game_event_line.dart';
import 'package:famchat/games/widgets/game_screen.dart';
import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';

const chatId = '01JC0000000000000000000001';

ChatDto direct(String a, String b) => ChatDto(
  id: chatId,
  kind: 'direct',
  title: null,
  createdBy: a,
  currentEpoch: 1,
  epochReady: true,
  lastSeq: 0,
  lastMessageAt: null,
  createdAt: 1,
  members: [
    MemberDto(userId: a, joinedSeq: 0, lastReadSeq: 0),
    MemberDto(userId: b, joinedSeq: 0, lastReadSeq: 0),
  ],
);

var _seq = 0;

MessageRow msg(String from, Plaintext p, {String? id}) {
  _seq++;
  return MessageRow(
    id: id ?? 'r$_seq',
    chatId: chatId,
    seq: _seq,
    senderUserId: from,
    senderDeviceId: 'x',
    kind: p.kind,
    body: jsonEncode(p.toJson()),
    targetId: p is MoveBody ? p.target : null,
    envelope: null,
    createdAt: DateTime.now().millisecondsSinceEpoch,
    state: 'sent',
  );
}

MessageRow game(String id, GameType t, String first) =>
    msg(first, GameBody(t, first), id: id);

MessageRow move(
  String from,
  String g,
  GameType t,
  int ply,
  Map<String, Object?> action,
) => msg(from, MoveBody(g, t, ply, action));

/// Tic-tac-toe plays alternating from [first], starting at ply 0.
List<MessageRow> tttPlays(
  String g,
  String first,
  String second,
  List<int> cells,
) => [
  for (var i = 0; i < cells.length; i++)
    move(i.isEven ? first : second, g, GameType.tictactoe, i, {
      'type': 'play',
      'cell': cells[i],
    }),
];

void main() {
  late FakeChatBackend backend;
  late TestDevice alice, bob;

  setUp(() async {
    _seq = 0;
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    bob = await backend.addUser('Bob');
  });

  Future<void> open(
    WidgetTester tester, {
    List<MessageRow> messages = const [],
    Size size = const Size(400, 800),
  }) async {
    setWindow(tester, size);
    await pumpChatApp(tester, alice);
    await inApp(tester, () async {
      await alice.db.upsertChat(direct(alice.userId, bob.userId));
      for (final m in messages) {
        await alice.db.insertMessageIfAbsent(m);
      }
    });
    ProviderScope.containerOf(tester.element(find.byType(FamChatApp)))
        .read(routerProvider)
        .go('/chats/$chatId');
    await settle(tester);
  }

  Future<List<Map<String, Object?>>> outbox(WidgetTester tester) async => [
    for (final r in await inApp(
      tester,
      () => alice.db.pendingOutbox(alice.deviceId),
    ))
      jsonDecode(r.body!) as Map<String, Object?>,
  ];

  Future<void> openBoard(WidgetTester tester) async {
    await tester.tap(find.byType(GameCard).last);
    await settle(tester);
  }

  chatTestWidgets('game card shows Your turn and opens the board', (
    tester,
  ) async {
    await open(
      tester,
      messages: [game('g1', GameType.tictactoe, alice.userId)],
    );
    final card = find.byType(GameCard);
    expect(card, findsOneWidget);
    expect(
      find.descendant(
        of: card,
        matching: find.text('✕ Tic-tac-toe', findRichText: true),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('Your turn')),
      findsOneWidget,
    );
    await openBoard(tester);
    expect(find.byType(GameScreen), findsOneWidget);
    final board = tester.widget<BoardView>(
      find.descendant(
        of: find.byType(GameScreen),
        matching: find.byType(BoardView),
      ),
    );
    expect(board.enabled, isTrue);
    expect(board.mySide, Side.first);
  });

  chatTestWidgets("the card names the other player's turn and the winner", (
    tester,
  ) async {
    await open(
      tester,
      messages: [
        game('g1', GameType.tictactoe, bob.userId),
        ...tttPlays('g1', bob.userId, alice.userId, [0, 3, 1, 4, 2]),
        game('g2', GameType.tictactoe, bob.userId),
      ],
    );
    expect(find.text('Bob won'), findsOneWidget);
    expect(find.text("Bob's turn"), findsOneWidget);
  });

  chatTestWidgets('playing on the board sends a move with the current ply', (
    tester,
  ) async {
    await open(
      tester,
      messages: [
        game('g1', GameType.tictactoe, alice.userId),
        ...tttPlays('g1', alice.userId, bob.userId, [0, 4]),
      ],
    );
    await openBoard(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(GameScreen),
        matching: find.byKey(const Key('sq-8')),
      ),
    );
    await settle(tester);
    final sent = await outbox(tester);
    expect(sent, [
      {
        'kind': 'move',
        'target': 'g1',
        'game': 'tictactoe',
        'ply': 2,
        'action': {'type': 'play', 'cell': 8},
      },
    ]);
    // The pending move shows at once: now it's Bob's turn.
    expect(
      find.descendant(
        of: find.byType(GameScreen),
        matching: find.textContaining("Bob's turn"),
      ),
      findsOneWidget,
    );
  });

  chatTestWidgets('resigns and draw offers show as lines in the chat; plays do not', (
    tester,
  ) async {
    await open(
      tester,
      messages: [
        game('g1', GameType.chess, alice.userId),
        ...[
          move(alice.userId, 'g1', GameType.chess, 0, {'type': 'play', 'from': 12, 'to': 28}),
          move(bob.userId, 'g1', GameType.chess, 1, {'type': 'draw_offer'}),
          move(alice.userId, 'g1', GameType.chess, 1, {'type': 'draw_decline'}),
          move(alice.userId, 'g1', GameType.chess, 1, {'type': 'resign'}),
        ],
      ],
    );
    expect(find.byType(GameEventLine), findsNWidgets(3));
    expect(find.text('🤝 Bob offered a draw in Chess'), findsOneWidget);
    expect(find.text('You declined a draw in Chess'), findsOneWidget);
    expect(find.text('🏳 You resigned at Chess'), findsOneWidget);
    await tester.tap(find.text('🏳 You resigned at Chess'));
    await settle(tester);
    expect(find.byType(GameScreen), findsOneWidget);
  });

  chatTestWidgets('resign asks for confirmation then sends resign', (
    tester,
  ) async {
    await open(tester, messages: [game('g1', GameType.chess, alice.userId)]);
    await openBoard(tester);
    await tester.tap(find.byTooltip('Game options'));
    await settle(tester);
    await tester.tap(find.text('Resign'));
    await settle(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(await outbox(tester), isEmpty);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, 'Resign'),
      ),
    );
    await settle(tester);
    final sent = await outbox(tester);
    expect(sent.single['action'], {'type': 'resign'});
    expect(sent.single['ply'], 0);
    expect(
      find.descendant(
        of: find.byType(GameScreen),
        matching: find.textContaining('Bob won'),
      ),
      findsOneWidget,
    );
  });

  chatTestWidgets('draw offer banner accept sends draw_accept', (tester) async {
    await open(
      tester,
      messages: [
        game('g1', GameType.chess, alice.userId),
        move(bob.userId, 'g1', GameType.chess, 0, {'type': 'draw_offer'}),
      ],
    );
    await openBoard(tester);
    expect(find.text('Bob offers a draw'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Accept'));
    await settle(tester);
    final sent = await outbox(tester);
    expect(sent.single['action'], {'type': 'draw_accept'});
    expect(find.text('Bob offers a draw'), findsNothing);
  });

  chatTestWidgets('rematch flips who goes first', (tester) async {
    await open(
      tester,
      messages: [
        game('g1', GameType.tictactoe, alice.userId),
        ...tttPlays('g1', alice.userId, bob.userId, [0, 3, 1, 4, 2]),
        game('g2', GameType.tictactoe, alice.userId),
        ...tttPlays('g2', alice.userId, bob.userId, [0, 3, 1, 4, 2]),
      ],
    );
    // Only the newest game offers a rematch.
    expect(find.widgetWithText(TextButton, 'Rematch'), findsOneWidget);
    expect(find.text('You won'), findsNWidgets(2));
    await tester.tap(find.widgetWithText(TextButton, 'Rematch'));
    await settle(tester);
    final sent = await outbox(tester);
    expect(sent.single, {
      'kind': 'game',
      'game': 'tictactoe',
      'first': bob.userId,
    });
  });

  chatTestWidgets('a double-tapped rematch starts one game', (tester) async {
    await open(
      tester,
      messages: [
        game('g1', GameType.tictactoe, alice.userId),
        ...tttPlays('g1', alice.userId, bob.userId, [0, 3, 1, 4, 2]),
      ],
    );
    final rematch = find.widgetWithText(TextButton, 'Rematch');
    await tester.tap(rematch);
    await tester.tap(rematch);
    await settle(tester);
    expect(
      (await outbox(tester)).where((m) => m['kind'] == 'game'),
      hasLength(1),
    );
    expect(find.byType(GameScreen), findsOneWidget);
  });

  chatTestWidgets('rematch opens the game already running', (tester) async {
    await open(
      tester,
      messages: [
        game('g1', GameType.tictactoe, alice.userId),
        ...tttPlays('g1', alice.userId, bob.userId, [0, 3, 1, 4, 2]),
      ],
    );
    // Rematch is tapped just as Bob's rematch lands.
    final onPressed = tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Rematch'))
        .onPressed!;
    await inApp(
      tester,
      () => alice.db.insertMessageIfAbsent(
        game('g2', GameType.tictactoe, bob.userId),
      ),
    );
    await settle(tester);
    expect(find.widgetWithText(TextButton, 'Rematch'), findsNothing);
    onPressed();
    await settle(tester);
    expect(await outbox(tester), isEmpty);
    expect(
      find.descendant(
        of: find.byType(GameScreen),
        matching: find.text("Bob's turn"),
      ),
      findsOneWidget,
    );
  });

  chatTestWidgets('an inert newer game leaves Rematch on the real one', (
    tester,
  ) async {
    await open(
      tester,
      messages: [
        game('g1', GameType.tictactoe, alice.userId),
        // Bob's simultaneous rematch: never started.
        game('g2', GameType.tictactoe, bob.userId),
        ...tttPlays('g1', alice.userId, bob.userId, [0, 3, 1, 4, 2]),
      ],
    );
    expect(find.text('Game not started'), findsOneWidget);
    final card = find.ancestor(
      of: find.text('You won'),
      matching: find.byType(GameCard),
    );
    expect(
      find.descendant(
        of: card,
        matching: find.widgetWithText(TextButton, 'Rematch'),
      ),
      findsOneWidget,
    );
  });

  chatTestWidgets('an inert game offers to open the running one', (
    tester,
  ) async {
    await open(
      tester,
      messages: [
        game('g1', GameType.chess, alice.userId),
        game('g2', GameType.checkers, bob.userId),
      ],
    );
    await tester.tap(
      find.ancestor(
        of: find.text('Game not started'),
        matching: find.byType(GameCard),
      ),
    );
    await settle(tester);
    final screen = find.byType(GameScreen);
    expect(
      find.descendant(of: screen, matching: find.text('Checkers')),
      findsOneWidget,
    );
    expect(find.text('A game is already running'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Open'));
    await settle(tester);
    expect(
      find.descendant(of: screen, matching: find.text('Chess')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: screen, matching: find.text('Your turn')),
      findsOneWidget,
    );
    expect(find.text('A game is already running'), findsNothing);
  });

  chatTestWidgets('a game that never resolves says it is not available', (
    tester,
  ) async {
    await open(tester, messages: [game('g1', GameType.chess, alice.userId)]);
    unawaited(openGame(tester.element(find.byType(GameCard)), chatId, 'gone'));
    await settle(tester);
    expect(find.text("This game isn't available"), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  chatTestWidgets('a double-tapped draw accept sends one move', (tester) async {
    await open(
      tester,
      messages: [
        game('g1', GameType.chess, alice.userId),
        move(bob.userId, 'g1', GameType.chess, 0, {'type': 'draw_offer'}),
      ],
    );
    await openBoard(tester);
    final accept = find.widgetWithText(TextButton, 'Accept');
    await tester.tap(accept);
    await tester.tap(accept, warnIfMissed: false);
    await settle(tester);
    expect(await outbox(tester), hasLength(1));
  });

  chatTestWidgets('a game row after my message leaves its read ticks', (
    tester,
  ) async {
    await open(
      tester,
      messages: [
        msg(alice.userId, const TextBody('want to play?')),
        game('g1', GameType.chess, alice.userId),
      ],
    );
    await inApp(tester, () => alice.db.setMemberRead(chatId, bob.userId, 2));
    await settle(tester);
    expect(find.byKey(const Key('read-icon')), findsOneWidget);
  });

  chatTestWidgets('a read-only chat says Game paused', (tester) async {
    backend.markFormer(bob.userId);
    await open(tester, messages: [game('g1', GameType.chess, alice.userId)]);
    expect(find.text('Your turn'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(GameCard),
        matching: find.text('Game paused'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('game-bar')),
        matching: find.textContaining('Game paused', findRichText: true),
      ),
      findsOneWidget,
    );
    await openBoard(tester);
    expect(
      tester.widget<Text>(find.byKey(const Key('game-status'))).data,
      'Game paused',
    );
  });

  chatTestWidgets('read-only chat shows board without controls', (
    tester,
  ) async {
    backend.markFormer(bob.userId);
    await open(
      tester,
      messages: [
        game('g1', GameType.chess, alice.userId),
        move(bob.userId, 'g1', GameType.chess, 0, {'type': 'draw_offer'}),
      ],
    );
    await openBoard(tester);
    expect(find.byType(GameScreen), findsOneWidget);
    final board = tester.widget<BoardView>(
      find.descendant(
        of: find.byType(GameScreen),
        matching: find.byType(BoardView),
      ),
    );
    expect(board.enabled, isFalse);
    expect(find.byTooltip('Game options'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Accept'), findsNothing);
  });

  chatTestWidgets('read-only chat offers no rematch', (tester) async {
    backend.markFormer(bob.userId);
    await open(
      tester,
      messages: [
        game('g1', GameType.tictactoe, alice.userId),
        ...tttPlays('g1', alice.userId, bob.userId, [0, 3, 1, 4, 2]),
      ],
    );
    expect(find.text('You won'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Rematch'), findsNothing);
  });

  chatTestWidgets('a game won on points shows the score and both names', (
    tester,
  ) async {
    // A random playout: Alice (first) draws the last line but loses 7-9.
    final lines =
        'f31,s23,f32,s13,f39,s9,s38,f14,s36,f37,s19,f1,s0,f6,s8,f15,f5,s12,'
                'f30,f35,s28,f27,s21,f16,f20,s11,f34,s24,f22,f29,s7,s2,s26,'
                's10,s18,s33,s3,s25,f4,f17'
            .split(',');
    await open(
      tester,
      messages: [
        game('g1', GameType.dotsandboxes, alice.userId),
        for (var i = 0; i < lines.length; i++)
          move(
            lines[i][0] == 'f' ? alice.userId : bob.userId,
            'g1',
            GameType.dotsandboxes,
            i,
            {'type': 'play', 'line': int.parse(lines[i].substring(1))},
          ),
      ],
    );
    await openBoard(tester);
    expect(
      tester.widget<Text>(find.byKey(const Key('game-status'))).data,
      'Bob won · 9–7',
    );
    final screen = find.byType(GameScreen);
    expect(
      find.descendant(
        of: screen,
        matching: find.byKey(const Key('name-first')),
      ),
      findsOneWidget,
    );
    Text inScreen(String key) => tester.widget<Text>(
      find.descendant(of: screen, matching: find.byKey(Key(key))),
    );
    expect(inScreen('name-first').data, 'You');
    expect(inScreen('name-second').data, 'Bob');
  });

  chatTestWidgets('inert game card says Game not started', (tester) async {
    await open(
      tester,
      messages: [
        game('g1', GameType.chess, alice.userId),
        game('g2', GameType.checkers, bob.userId),
      ],
    );
    expect(find.text('Game not started'), findsOneWidget);
    expect(find.text('Your turn'), findsOneWidget);
  });

  final blur = find.byKey(const Key('game-overlay-blur'));
  final panel = find.byKey(const Key('game-panel'));

  chatTestWidgets('on a phone the board opens as a blurred overlay', (
    tester,
  ) async {
    await open(tester, messages: [game('g1', GameType.chess, alice.userId)]);
    await openBoard(tester);
    expect(find.byType(GameScreen), findsOneWidget);
    expect(
      tester.widget<BackdropFilter>(blur).filter,
      ImageFilter.blur(sigmaX: overlayBlurSigma, sigmaY: overlayBlurSigma),
    );
    // The conversation stays underneath, not replaced by a page.
    expect(find.byType(GameCard, skipOffstage: false), findsOneWidget);
    expect(find.text('Chess'), findsOneWidget);
    expect(find.text('with Bob'), findsOneWidget);
    // The board fills the panel's width, less its margins.
    final p = tester.getRect(panel);
    expect(p.width, greaterThan(360));
    final board = tester.getSize(
      find.descendant(of: panel, matching: find.byType(BoardView)),
    );
    expect(board.width, closeTo(p.width - 32, 0.5));
    expect(board.height, closeTo(board.width, 0.5));
  });

  chatTestWidgets('tapping outside the panel closes the overlay', (
    tester,
  ) async {
    await open(tester, messages: [game('g1', GameType.chess, alice.userId)]);
    await openBoard(tester);
    final p = tester.getRect(panel);
    await tester.tapAt(Offset(p.center.dx, p.top - 8));
    await settle(tester);
    expect(find.byType(GameScreen), findsNothing);
    expect(blur, findsNothing);
  });

  chatTestWidgets('taps and drags on the panel keep the overlay open', (
    tester,
  ) async {
    await open(
      tester,
      messages: [game('g1', GameType.tictactoe, alice.userId)],
    );
    await openBoard(tester);
    // The panel's own padding, the status line and the board.
    final p = tester.getRect(panel);
    await tester.tapAt(p.bottomCenter + const Offset(0, -4));
    await tester.tap(find.byKey(const Key('game-status')));
    await settle(tester);
    expect(find.byType(GameScreen), findsOneWidget);
    final square = find.descendant(
      of: panel,
      matching: find.byKey(const Key('sq-4')),
    );
    // A drag from the board that ends outside the panel isn't an outside tap.
    await tester.dragFrom(tester.getCenter(square), const Offset(0, 400));
    await settle(tester);
    expect(find.byType(GameScreen), findsOneWidget);
    await tester.tap(square);
    await settle(tester);
    expect(find.byType(GameScreen), findsOneWidget);
    expect((await outbox(tester)).single['action'], {
      'type': 'play',
      'cell': 4,
    });
  });

  chatTestWidgets('the close button and back close the overlay', (
    tester,
  ) async {
    await open(tester, messages: [game('g1', GameType.chess, alice.userId)]);
    await openBoard(tester);
    await tester.tap(find.byTooltip('Close'));
    await settle(tester);
    expect(find.byType(GameScreen), findsNothing);

    await tester.tap(find.byKey(const Key('game-bar')));
    await settle(tester);
    expect(find.byType(GameScreen), findsOneWidget);
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.byType(GameScreen), findsNothing);
    // Back closed the overlay only, not the conversation.
    expect(find.byType(GameCard), findsOneWidget);
  });

  chatTestWidgets('the barrier is labelled Close for screen readers', (
    tester,
  ) async {
    await open(tester, messages: [game('g1', GameType.chess, alice.userId)]);
    await openBoard(tester);
    final barrier = tester.widget<AnimatedModalBarrier>(
      find.byType(AnimatedModalBarrier).last,
    );
    expect(barrier.semanticsLabel, 'Close');
    expect(barrier.dismissible, isTrue);
  });

  chatTestWidgets('with reduced motion the overlay appears at once', (
    tester,
  ) async {
    await open(tester, messages: [game('g1', GameType.chess, alice.userId)]);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pump();
    await tester.tap(find.byType(GameCard));
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<FadeTransition>(
            find
                .ancestor(of: panel, matching: find.byType(FadeTransition))
                .first,
          )
          .opacity
          .value,
      1,
    );
    await settle(tester);
  });

  chatTestWidgets('Rematch on a finished board starts the next game in place', (
    tester,
  ) async {
    await open(
      tester,
      messages: [
        game('g1', GameType.tictactoe, alice.userId),
        ...tttPlays('g1', alice.userId, bob.userId, [0, 3, 1, 4, 2]),
      ],
    );
    await openBoard(tester);
    await tester.tap(find.byKey(const Key('game-rematch')));
    await settle(tester);
    expect((await outbox(tester)).single, {
      'kind': 'game',
      'game': 'tictactoe',
      'first': bob.userId,
    });
    expect(find.byType(GameScreen), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('game-status'))).data,
      "Bob's turn",
    );
    expect(find.byKey(const Key('game-rematch')), findsNothing);
  });

  chatTestWidgets('the card shows a readable board, players and score', (
    tester,
  ) async {
    await open(
      tester,
      messages: [
        game('g1', GameType.reversi, alice.userId),
        move(alice.userId, 'g1', GameType.reversi, 0, {
          'type': 'play',
          'cell': 20,
        }),
      ],
    );
    final card = find.byType(GameCard);
    final board = tester.getSize(
      find.descendant(
        of: card,
        matching: find.byKey(const Key('game-card-board')),
      ),
    );
    expect(board.width, greaterThanOrEqualTo(280));
    expect(board.width, lessThanOrEqualTo(GameCard.maxWidth));
    expect(board.height, closeTo(board.width, 0.5));
    expect(
      find.descendant(of: card, matching: find.byKey(const Key('name-first'))),
      findsOneWidget,
    );
    Text inCard(String key) => tester.widget<Text>(
      find.descendant(of: card, matching: find.byKey(Key(key))),
    );
    expect(inCard('name-first').data, 'You');
    expect(inCard('name-second').data, 'Bob');
    expect(inCard('count-first').data, '4');
    expect(inCard('count-second').data, '1');
    expect(
      find.descendant(of: card, matching: find.text("Bob's turn")),
      findsOneWidget,
    );
  });

  chatTestWidgets('a Four in a Row card keeps its board shape', (tester) async {
    await open(
      tester,
      size: const Size(1200, 900),
      messages: [game('g1', GameType.fourinarow, alice.userId)],
    );
    final board = tester.getSize(find.byKey(const Key('game-card-board')));
    expect(board.width / board.height, closeTo(7 / 6, 0.01));
    expect(board.width, lessThanOrEqualTo(GameCard.maxWidth));
  });

  chatTestWidgets('an inert card is dimmed', (tester) async {
    await open(
      tester,
      messages: [
        game('g1', GameType.chess, alice.userId),
        game('g2', GameType.checkers, bob.userId),
      ],
    );
    double opacityOf(String text) => tester
        .widget<Opacity>(
          find
              .ancestor(of: find.text(text), matching: find.byType(Opacity))
              .first,
        )
        .opacity;
    expect(opacityOf('Game not started'), 0.5);
    expect(opacityOf('Your turn'), 1);
  });

  chatTestWidgets('a wide window opens the same overlay', (tester) async {
    await open(
      tester,
      size: const Size(1200, 900),
      messages: [game('g1', GameType.checkers, alice.userId)],
    );
    await openBoard(tester);
    final screen = find.byType(GameScreen);
    expect(blur, findsOneWidget);
    expect(tester.getSize(screen).width, lessThanOrEqualTo(560));
    final board = tester.getSize(
      find.descendant(of: screen, matching: find.byType(BoardView)),
    );
    expect(board.width, closeTo(board.height, 0.5));
  });

  chatTestWidgets('opening the board marks the chat read', (tester) async {
    await open(tester, messages: [game('g1', GameType.chess, bob.userId)]);
    await inApp(tester, () => alice.db.setMyLastRead(chatId, 0));
    await openBoard(tester);
    expect(
      (await inApp(tester, () => alice.db.chatById(chatId)))!.myLastReadSeq,
      1,
    );
  });
}
