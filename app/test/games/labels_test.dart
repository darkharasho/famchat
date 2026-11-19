import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/message_changes.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/games/game_state.dart';
import 'package:famchat/games/labels.dart';
import 'package:famchat/games/rules.dart';
import 'package:flutter_test/flutter_test.dart';

var _n = 0;

MessageRow row(String sender, Plaintext p, {String? id}) {
  _n++;
  return MessageRow(
    id: id ?? 'm$_n',
    chatId: 'c',
    seq: _n,
    senderUserId: sender,
    senderDeviceId: '$sender-d',
    kind: p.kind,
    body: jsonEncode(p.toJson()),
    targetId: p is MoveBody ? p.target : null,
    envelope: null,
    createdAt: _n,
    state: 'sent',
  );
}

MessageRow mv(
  String sender,
  GameType t,
  int ply,
  Map<String, Object?> a, {
  String target = 'g',
}) => row(sender, MoveBody(target, t, ply, a));

void main() {
  test('list labels', () {
    expect(
      gameListLabel(row('A', const GameBody(GameType.checkers, 'A'))),
      '🎲 Started a game of Checkers',
    );
    String? l(Map<String, Object?> a) =>
        gameListLabel(mv('A', GameType.chess, 0, a));
    expect(l({'type': 'play', 'uci': 'e2e4'}), '♟ Moved in Chess');
    expect(l({'type': 'resign'}), '🏳 Resigned at Chess');
    expect(l({'type': 'draw_offer'}), '🤝 Offered a draw in Chess');
    expect(l({'type': 'draw_accept'}), '🤝 Accepted a draw in Chess');
    expect(l({'type': 'draw_decline'}), 'Declined a draw in Chess');
    expect(l({'type': 'poke'}), '👉 Poked in Chess');
  });

  test('list label is null for other kinds and undecodable bodies', () {
    expect(gameListLabel(row('A', const TextBody('hi'))), isNull);
    expect(
      gameListLabel(
        row(
          'A',
          const GameBody(GameType.chess, 'A'),
        ).copyWith(body: const Value('nope')),
      ),
      isNull,
    );
  });

  group('push', () {
    late ChatDb db;
    setUp(() async {
      db = ChatDb(NativeDatabase.memory());
      await db.upsertChat(
        ChatDto(
          id: 'c',
          kind: 'direct',
          title: null,
          createdBy: 'A',
          currentEpoch: 1,
          epochReady: true,
          lastSeq: 0,
          lastMessageAt: 1,
          createdAt: 1,
          members: [
            MemberDto(userId: 'A', joinedSeq: 0, lastReadSeq: 0),
            MemberDto(userId: 'B', joinedSeq: 0, lastReadSeq: 0),
          ],
        ),
      );
    });
    tearDown(() => db.close());

    Future<String?> push(MessageRow m) => gamePushLabel(db, 'c', m);

    test('game, resign, offer, accept, decline', () async {
      expect(
        await push(row('A', const GameBody(GameType.tictactoe, 'A'))),
        '🎲 Started a game of Tic-tac-toe',
      );
      Future<String?> a(String t) =>
          push(mv('A', GameType.chess, 3, {'type': t}));
      expect(await a('resign'), '🏳 Resigned at Chess');
      expect(await a('draw_offer'), '🤝 Offered a draw in Chess');
      expect(await a('draw_accept'), '🤝 Draw in Chess');
      expect(await a('draw_decline'), 'Declined a draw in Chess');
      expect(await a('poke'), '👉 Poked you · your turn in Chess');
    });

    test('a play is your turn', () async {
      await db.insertMessageIfAbsent(
        row('A', const GameBody(GameType.tictactoe, 'A'), id: 'g'),
      );
      final m = mv('A', GameType.tictactoe, 0, {'type': 'play', 'cell': 4});
      expect(await push(m), '♟ Your turn in Tic-tac-toe');
      // already stored: not counted twice
      await db.insertMessageIfAbsent(m);
      expect(await push(m), '♟ Your turn in Tic-tac-toe');
    });

    test('a winning play says You lost, a drawing play says Draw', () async {
      await db.insertMessageIfAbsent(
        row('A', const GameBody(GameType.tictactoe, 'A'), id: 'g'),
      );
      var ply = 0;
      for (final (who, cell) in [('A', 0), ('B', 3), ('A', 1), ('B', 4)]) {
        await db.insertMessageIfAbsent(
          mv(who, GameType.tictactoe, ply++, {'type': 'play', 'cell': cell}),
        );
      }
      expect(
        await push(mv('A', GameType.tictactoe, 4, {'type': 'play', 'cell': 2})),
        '♟ You lost at Tic-tac-toe',
      );
    });

    test('a drawing play says Draw', () async {
      await db.insertMessageIfAbsent(
        row('A', const GameBody(GameType.tictactoe, 'A'), id: 'g'),
      );
      var ply = 0;
      // X: 0 1 5 6 7  O: 2 3 4 8 -> final X at 7 fills the board without a line
      for (final (who, cell) in [
        ('A', 0),
        ('B', 1),
        ('A', 2),
        ('B', 4),
        ('A', 3),
        ('B', 6),
        ('A', 5),
        ('B', 8),
      ]) {
        await db.insertMessageIfAbsent(
          mv(who, GameType.tictactoe, ply++, {'type': 'play', 'cell': cell}),
        );
      }
      expect(
        await push(mv('A', GameType.tictactoe, 8, {'type': 'play', 'cell': 7})),
        '🤝 Draw in Tic-tac-toe',
      );
    });

    test('checkmating play says You lost at Chess', () async {
      await db.insertMessageIfAbsent(
        row('A', const GameBody(GameType.chess, 'A'), id: 'g'),
      );
      var ply = 0;
      for (final (who, u) in [('A', 'f2f3'), ('B', 'e7e5'), ('A', 'g2g4')]) {
        await db.insertMessageIfAbsent(
          mv(who, GameType.chess, ply++, {'type': 'play', 'uci': u}),
        );
      }
      expect(
        await push(mv('B', GameType.chess, 3, {'type': 'play', 'uci': 'd8h4'})),
        '♟ You lost at Chess',
      );
    });

    test('missing game row falls back to Moved in Chess', () async {
      expect(
        await push(
          mv('A', GameType.chess, 0, {
            'type': 'play',
            'uci': 'e2e4',
          }, target: 'nope'),
        ),
        '♟ Moved in Chess',
      );
    });

    test('an ignored (illegal or stale) play falls back to Moved in', () async {
      await db.insertMessageIfAbsent(
        row('A', const GameBody(GameType.tictactoe, 'A'), id: 'g'),
      );
      expect(
        await push(mv('A', GameType.tictactoe, 7, {'type': 'play', 'cell': 4})),
        '♟ Moved in Tic-tac-toe',
      );
    });

    /// Stores game 'g' of [t] (A first) and every play in [moves] but the
    /// last ("f12" is a first-player play of 12), and returns the last play.
    Future<MessageRow> playOut(GameType t, String key, String moves) async {
      await db.insertMessageIfAbsent(row('A', GameBody(t, 'A'), id: 'g'));
      final list = moves.split(',');
      MessageRow? last;
      for (var ply = 0; ply < list.length; ply++) {
        final m = list[ply];
        last = mv(m[0] == 'f' ? 'A' : 'B', t, ply, {
          'type': 'play',
          key: int.parse(m.substring(1)),
        });
        if (ply < list.length - 1) await db.insertMessageIfAbsent(last);
      }
      return last!;
    }

    test('a Reversi game ended by the loser\'s move says You won', () async {
      // Found by random playout: B makes the last move and loses.
      final last = await playOut(
        GameType.reversi,
        'cell',
        'f34,s44,f29,s22,f45,s43,f53,s46,f39,s62,f51,s47,f54,s61,f15,s42,'
            'f63,s25,f50,s31,f52,s20,f11,s60,f18,s55,f59,s26,f24,s16,f38,s32,'
            'f23,s58,f49,s13,f57,s17,f4,s19,f9,s21,f14,s3,f33,s40,f12,s30,'
            'f10,s8,f2,s6,f37,s0,f5,s48,f41,s1',
      );
      expect(last.senderUserId, 'B');
      expect(await push(last), '🏆 You won at Reversi');
    });

    test(
      'Dots and Boxes: the loser drawing the final line says You won',
      () async {
        // A draws the last line (claiming a box) but loses 7-9.
        final last = await playOut(
          GameType.dotsandboxes,
          'line',
          'f31,s23,f32,s13,f39,s9,s38,f14,s36,f37,s19,f1,s0,f6,s8,f15,f5,s12,'
              'f30,f35,s28,f27,s21,f16,f20,s11,f34,s24,f22,f29,s7,s2,s26,s10,'
              's18,s33,s3,s25,f4,f17',
        );
        expect(last.senderUserId, 'A');
        expect(await push(last), '🏆 You won at Dots and Boxes');
      },
    );

    test(
      'a Reversi play that leaves the opponent no move says Moved in',
      () async {
        // After B plays 40, A has no move and the turn comes back to B.
        final last = await playOut(
          GameType.reversi,
          'cell',
          'f34,s42,f20,s33,f32,s24,f50,s40',
        );
        expect(await push(last), '♟ Moved in Reversi');
      },
    );

    test('a play that keeps the sender\'s turn says ♟ Moved in Dots and '
        'Boxes', () async {
      await db.insertMessageIfAbsent(
        row('A', const GameBody(GameType.dotsandboxes, 'A'), id: 'g'),
      );
      var ply = 0;
      for (final (who, line) in [('A', 0), ('B', 4), ('A', 20)]) {
        await db.insertMessageIfAbsent(
          mv(who, GameType.dotsandboxes, ply++, {'type': 'play', 'line': line}),
        );
      }
      // B closes box 0 and goes again.
      final close = mv('B', GameType.dotsandboxes, 3, {
        'type': 'play',
        'line': 21,
      });
      expect(await push(close), '♟ Moved in Dots and Boxes');
      await db.insertMessageIfAbsent(close);
      // A plain line passes the turn.
      expect(
        await push(
          mv('B', GameType.dotsandboxes, 4, {'type': 'play', 'line': 10}),
        ),
        '♟ Your turn in Dots and Boxes',
      );
    });
  });

  group('timeline events', () {
    const names = {'A': 'Ann', 'B': 'Bob'};

    Map<String, GameEvent> events(
      List<MessageRow> rows, {
      String me = 'A',
      bool readOnly = false,
    }) => gameEventsOf(
      rows,
      plays: playResults(rows, ['A', 'B']),
      games: deriveGames(rows, ['A', 'B']),
      me: me,
      readOnly: readOnly,
      nameOf: (u) => u == me ? 'You' : names[u]!,
      shown: (m) => !timelineHiddenKinds.contains(m.kind),
    );

    MessageRow g() =>
        row('A', const GameBody(GameType.tictactoe, 'A'), id: 'g');
    MessageRow p(String who, int ply, int cell) =>
        mv(who, GameType.tictactoe, ply, {'type': 'play', 'cell': cell});
    MessageRow poke(String who, int ply) =>
        mv(who, GameType.tictactoe, ply, {'type': 'poke'});
    const yourTurn = ' · Your turn';

    test('a play says who moved; the mover to come sees Your turn', () {
      final rows = [g(), p('A', 0, 4)];
      expect(events(rows), {
        rows[1].id: (
          gameId: 'g',
          text: '♟ You moved in Tic-tac-toe',
          suffix: null,
          poke: false,
        ),
      });
      expect(events(rows, me: 'B')[rows[1].id], (
        gameId: 'g',
        text: '♟ Ann moved in Tic-tac-toe',
        suffix: yourTurn,
        poke: false,
      ));
    });

    test('no Your turn in a read-only chat', () {
      final rows = [g(), p('A', 0, 4)];
      expect(events(rows, me: 'B', readOnly: true)[rows[1].id]!.suffix, isNull);
    });

    test('a run of plays collapses to the newest line', () {
      final rows = [g(), p('A', 0, 0), p('B', 1, 4), p('A', 2, 8)];
      expect(events(rows).keys, [rows[3].id]);
    });

    test('a message between plays keeps both; Your turn on the newest', () {
      final rows = [
        g(),
        p('A', 0, 0),
        row('B', const TextBody('hi')),
        p('B', 1, 4),
      ];
      final e = events(rows);
      expect(e.keys, [rows[1].id, rows[3].id]);
      expect(e[rows[1].id]!.suffix, isNull);
      expect(e[rows[3].id]!.text, '♟ Bob moved in Tic-tac-toe');
      expect(e[rows[3].id]!.suffix, yourTurn);
    });

    test('a hidden row between plays does not break the run', () {
      final rows = [
        g(),
        p('A', 0, 0),
        row('B', const ReactionBody('g', '👍')),
        p('B', 1, 4),
      ];
      expect(events(rows).keys, [rows[3].id]);
    });

    test('ignored plays get no line', () {
      final rows = [
        g(),
        p('A', 0, 0),
        p('B', 0, 4),
        p('B', 1, 0),
        p('A', 1, 5),
      ];
      expect(events(rows).keys, [rows[1].id]);
    });

    test('a winning play names the winner', () {
      final rows = [
        g(),
        p('A', 0, 0),
        p('B', 1, 3),
        p('A', 2, 1),
        p('B', 3, 4),
        p('A', 4, 2),
      ];
      expect(events(rows)[rows.last.id], (
        gameId: 'g',
        text: '🏆 You won Tic-tac-toe',
        suffix: null,
        poke: false,
      ));
      expect(
        events(rows, me: 'B')[rows.last.id]!.text,
        '🏆 Ann won Tic-tac-toe',
      );
    });

    test('a drawing play says Draw in', () {
      var ply = 0;
      final rows = [
        g(),
        for (final (who, cell) in [
          ('A', 0),
          ('B', 1),
          ('A', 2),
          ('B', 4),
          ('A', 3),
          ('B', 6),
          ('A', 5),
          ('B', 8),
          ('A', 7),
        ])
          p(who, ply++, cell),
      ];
      expect(events(rows)[rows.last.id]!.text, '🤝 Draw in Tic-tac-toe');
    });

    test('a game ended by the loser\'s move names the winner', () {
      final moves =
          'f34,s44,f29,s22,f45,s43,f53,s46,f39,s62,f51,s47,f54,s61,f15,s42,'
                  'f63,s25,f50,s31,f52,s20,f11,s60,f18,s55,f59,s26,f24,s16,f38,s32,'
                  'f23,s58,f49,s13,f57,s17,f4,s19,f9,s21,f14,s3,f33,s40,f12,s30,'
                  'f10,s8,f2,s6,f37,s0,f5,s48,f41,s1'
              .split(',');
      final rows = [
        row('A', const GameBody(GameType.reversi, 'A'), id: 'g'),
        for (var i = 0; i < moves.length; i++)
          mv(moves[i][0] == 'f' ? 'A' : 'B', GameType.reversi, i, {
            'type': 'play',
            'cell': int.parse(moves[i].substring(1)),
          }),
      ];
      expect(rows.last.senderUserId, 'B');
      expect(events(rows)[rows.last.id]!.text, '🏆 You won Reversi');
    });

    test('pokes read per side, and break a run of plays', () {
      final rows = [g(), p('A', 0, 0), poke('A', 1), p('B', 1, 4)];
      final mine = events(rows);
      expect(mine.keys, [rows[1].id, rows[2].id, rows[3].id]);
      expect(mine[rows[2].id], (
        gameId: 'g',
        text: '👉 You poked Bob · Tic-tac-toe',
        suffix: null,
        poke: true,
      ));
      expect(
        events(rows, me: 'B')[rows[2].id]!.text,
        '👉 Ann poked you · Your turn in Tic-tac-toe',
      );
    });

    test('resigns and draw offers still show', () {
      final rows = [
        g(),
        p('A', 0, 0),
        mv('B', GameType.tictactoe, 1, {'type': 'resign'}),
      ];
      final e = events(rows);
      expect(e[rows[2].id]!.text, '🏳 Bob resigned at Tic-tac-toe');
      // the play before the resign has no Your turn: the game is over
      expect(e[rows[1].id]!.suffix, isNull);
    });

    test('lastPokeAt is my newest poke in that game', () {
      final rows = [g(), poke('A', 0), poke('A', 0), poke('B', 0)];
      expect(lastPokeAt(rows, 'g', 'A'), rows[2].createdAt);
      expect(lastPokeAt(rows, 'other', 'A'), isNull);
      expect(lastPokeAt([g()], 'g', 'A'), isNull);
    });
  });
}
