import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/chat/wire.dart';
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
}
