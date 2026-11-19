import 'dart:convert';

import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/games/game_state.dart';
import 'package:famchat/games/go_fish.dart';
import 'package:famchat/games/rules.dart';
import 'package:famchat/games/tictactoe.dart';
import 'package:flutter_test/flutter_test.dart';

var _n = 0;

MessageRow row(
  String sender,
  Plaintext p, {
  String? id,
  String state = 'sent',
}) {
  _n++;
  return MessageRow(
    id: id ?? 'm$_n',
    chatId: 'c',
    seq: state == 'pending' ? null : _n,
    senderUserId: sender,
    senderDeviceId: '$sender-d',
    kind: p.kind,
    body: jsonEncode(p.toJson()),
    targetId: p is MoveBody ? p.target : null,
    envelope: null,
    createdAt: _n,
    state: state,
  );
}

MessageRow game(String id, GameType t, String first, {String state = 'sent', int? seed}) =>
    row(first, GameBody(t, first, seed: seed), id: id, state: state);

MessageRow move(
  String sender,
  String target,
  GameType t,
  int ply,
  Map<String, Object?> action, {
  String state = 'sent',
}) => row(sender, MoveBody(target, t, ply, action), state: state);

MessageRow ttt(String sender, String g, int ply, int cell, {String? state}) =>
    move(sender, g, GameType.tictactoe, ply, {
      'type': 'play',
      'cell': cell,
    }, state: state ?? 'sent');

MessageRow chess(String sender, String g, int ply, Map<String, Object?> a) =>
    move(sender, g, GameType.chess, ply, a);

MessageRow uci(String sender, String g, int ply, String u) =>
    chess(sender, g, ply, {'type': 'play', 'uci': u});

const members = ['A', 'B'];

void main() {
  test('gofish without a seed is inert', () {
    final g = deriveGames([game('g', GameType.gofish, 'A')], members).single;
    expect(g.inert, isTrue);
    // ...so it doesn't block a new game.
    final both = deriveGames([
      game('g', GameType.gofish, 'A'),
      game('h', GameType.chess, 'B'),
    ], members);
    expect(both.last.inert, isFalse);
  });

  test('gofish with a seed deals from it and replays asks', () {
    final dealt = GoFishBoard.deal(7);
    final rank = GoFishBoard.rankOf(dealt.hand(Side.first).first);
    final next = dealt.play({'rank': rank})!;
    final g = deriveGames([
      game('g', GameType.gofish, 'A', seed: 7),
      move('A', 'g', GameType.gofish, 0, {'type': 'play', 'rank': rank}),
    ], members).single;
    expect(g.inert, isFalse);
    expect(g.ply, 1);
    final b = g.board as GoFishBoard;
    expect(b.hand(Side.first), (next as GoFishBoard).hand(Side.first));
    expect(b.hand(Side.second), next.hand(Side.second));
    expect(g.toMoveUserId, next.toMove == Side.first ? 'A' : 'B');
  });

  test('chess with a stray seed plays normally', () {
    final g = deriveGames([
      game('g', GameType.chess, 'A', seed: 5),
      uci('A', 'g', 0, 'e2e4'),
    ], members).single;
    expect(g.inert, isFalse);
    expect(g.ply, 1);
  });

  test('a played game advances and alternates turns', () {
    final games = deriveGames([
      game('g', GameType.tictactoe, 'A'),
      ttt('A', 'g', 0, 0),
      ttt('B', 'g', 1, 4),
    ], members);
    expect(games, hasLength(1));
    final g = games.single;
    expect(g.id, 'g');
    expect(g.type, GameType.tictactoe);
    expect(g.firstUserId, 'A');
    expect(g.secondUserId, 'B');
    expect(g.ply, 2);
    expect(g.toMoveUserId, 'A');
    expect(g.over, isFalse);
    expect(g.inert, isFalse);
    expect(g.startedSeq, isNotNull);
    expect(g.sideOf('A'), Side.first);
    expect(g.sideOf('B'), Side.second);
    expect(g.sideOf('C'), isNull);
    expect(activeGame(games), same(g));
  });

  test('a finished game reports its winner and has no one to move', () {
    final games = deriveGames([
      game('g', GameType.tictactoe, 'B'),
      ttt('B', 'g', 0, 0),
      ttt('A', 'g', 1, 3),
      ttt('B', 'g', 2, 1),
      ttt('A', 'g', 3, 4),
      ttt('B', 'g', 4, 2),
      ttt('A', 'g', 5, 5),
    ], members);
    final g = games.single;
    expect(g.over, isTrue);
    expect(g.outcome!.winner, Side.first);
    expect(g.winnerUserId, 'B');
    expect(g.toMoveUserId, isNull);
    expect(g.ply, 5);
    expect(activeGame(games), isNull);
  });

  test('move from the wrong player is ignored', () {
    final g = deriveGames([
      game('g', GameType.tictactoe, 'A'),
      ttt('B', 'g', 0, 0),
      ttt('C', 'g', 0, 0),
    ], members).single;
    expect(g.ply, 0);
    expect(g.toMoveUserId, 'A');
  });

  test('second move with same ply is ignored', () {
    final g = deriveGames([
      game('g', GameType.tictactoe, 'A'),
      ttt('A', 'g', 0, 0),
      ttt('A', 'g', 0, 1),
      ttt('B', 'g', 1, 1),
    ], members).single;
    expect(g.ply, 2);
    // Cell 1 is B's, so A's stray second move never landed.
    expect(g.board.play({'cell': 1}), isNull);
    expect(g.board.play({'cell': 2}), isNotNull);
  });

  test('illegal play is ignored and later legal one applies', () {
    final g = deriveGames([
      game('g', GameType.tictactoe, 'A'),
      ttt('A', 'g', 0, 0),
      ttt('B', 'g', 1, 0),
      ttt('B', 'g', 1, 9),
      move('B', 'g', GameType.tictactoe, 1, {'type': 'play'}),
      ttt('B', 'g', 1, 4),
    ], members).single;
    expect(g.ply, 2);
    expect(g.toMoveUserId, 'A');
  });

  test('resign ends with the other player winning', () {
    final g = deriveGames([
      game('g', GameType.chess, 'A'),
      uci('A', 'g', 0, 'e2e4'),
      chess('A', 'g', 1, {'type': 'resign'}),
      uci('B', 'g', 1, 'e7e5'),
    ], members).single;
    expect(g.outcome!.reason, 'resigned');
    expect(g.outcome!.winner, Side.second);
    expect(g.winnerUserId, 'B');
    expect(g.ply, 1);
  });

  test('a stale-ply resign is ignored', () {
    final g = deriveGames([
      game('g', GameType.chess, 'A'),
      uci('A', 'g', 0, 'e2e4'),
      chess('B', 'g', 0, {'type': 'resign'}),
    ], members).single;
    expect(g.over, isFalse);
  });

  group('draws', () {
    test('offer then accept is a draw', () {
      final g = deriveGames([
        game('g', GameType.chess, 'A'),
        uci('A', 'g', 0, 'e2e4'),
        chess('A', 'g', 1, {'type': 'draw_offer'}),
        chess('B', 'g', 1, {'type': 'draw_accept'}),
      ], members).single;
      expect(g.outcome!.winner, isNull);
      expect(g.outcome!.reason, 'agreed');
      expect(g.winnerUserId, isNull);
      expect(g.ply, 1);
    });

    test('accept without offer is ignored, and so is accepting my own', () {
      final g = deriveGames([
        game('g', GameType.chess, 'A'),
        chess('B', 'g', 0, {'type': 'draw_accept'}),
        chess('A', 'g', 0, {'type': 'draw_offer'}),
        chess('A', 'g', 0, {'type': 'draw_accept'}),
        chess('A', 'g', 0, {'type': 'draw_decline'}),
      ], members).single;
      expect(g.over, isFalse);
      expect(g.drawOfferedBy, 'A');
    });

    test('decline clears the offer', () {
      final g = deriveGames([
        game('g', GameType.chess, 'A'),
        chess('A', 'g', 0, {'type': 'draw_offer'}),
        chess('B', 'g', 0, {'type': 'draw_decline'}),
        chess('B', 'g', 0, {'type': 'draw_accept'}),
      ], members).single;
      expect(g.over, isFalse);
      expect(g.drawOfferedBy, isNull);
    });

    test('opponent play clears the offer', () {
      final g = deriveGames([
        game('g', GameType.chess, 'A'),
        uci('A', 'g', 0, 'e2e4'),
        chess('A', 'g', 1, {'type': 'draw_offer'}),
        uci('B', 'g', 1, 'e7e5'),
        chess('B', 'g', 2, {'type': 'draw_accept'}),
      ], members).single;
      expect(g.over, isFalse);
      expect(g.drawOfferedBy, isNull);
      expect(g.ply, 2);
    });
  });

  test('tic-tac-toe ignores draw_offer', () {
    final g = deriveGames([
      game('g', GameType.tictactoe, 'A'),
      move('A', 'g', GameType.tictactoe, 0, {'type': 'draw_offer'}),
      move('B', 'g', GameType.tictactoe, 0, {'type': 'draw_accept'}),
    ], members).single;
    expect(g.drawOfferedBy, isNull);
    expect(g.over, isFalse);
  });

  test('unknown actions and mismatched game types are ignored', () {
    final g = deriveGames([
      game('g', GameType.tictactoe, 'A'),
      move('A', 'g', GameType.tictactoe, 0, {'type': 'undo'}),
      move('A', 'g', GameType.chess, 0, {'type': 'resign'}),
      ttt('A', 'nope', 0, 0),
    ], members).single;
    expect(g.over, isFalse);
    expect(g.ply, 0);
  });

  test(
    'second game while one is unfinished is inert and its moves ignored',
    () {
      final games = deriveGames([
        game('g1', GameType.tictactoe, 'A'),
        game('g2', GameType.tictactoe, 'B'),
        ttt('B', 'g2', 0, 0),
        ttt('A', 'g1', 0, 4),
      ], members);
      expect(games.map((g) => g.id), ['g1', 'g2']);
      expect(games[0].inert, isFalse);
      expect(games[0].ply, 1);
      expect(games[1].inert, isTrue);
      expect(games[1].ply, 0);
      expect(games[1].toMoveUserId, isNull);
      expect(activeGame(games)!.id, 'g1');
    },
  );

  test('a game started after the first finished is active', () {
    final games = deriveGames([
      game('g1', GameType.chess, 'A'),
      chess('B', 'g1', 0, {'type': 'resign'}),
      game('g2', GameType.tictactoe, 'B'),
      ttt('B', 'g2', 0, 0),
    ], members);
    expect(games[0].over, isTrue);
    expect(games[1].inert, isFalse);
    expect(games[1].ply, 1);
    expect(activeGame(games)!.id, 'g2');
  });

  test('games in a chat without exactly two members are inert', () {
    final rows = [game('g', GameType.tictactoe, 'A'), ttt('A', 'g', 0, 0)];
    for (final m in [
      ['A'],
      ['A', 'B', 'C'],
      ['B', 'C'],
    ]) {
      final g = deriveGames(rows, m).single;
      expect(g.inert, isTrue, reason: '$m');
      expect(g.ply, 0);
      expect(g.toMoveUserId, isNull);
    }
    expect(activeGame(deriveGames(rows, ['A'])), isNull);
  });

  test('pending local move applies optimistically after sent moves', () {
    final g = deriveGames([
      game('g', GameType.tictactoe, 'A'),
      ttt('A', 'g', 0, 0),
      ttt('B', 'g', 1, 4),
      ttt('A', 'g', 2, 8, state: 'pending'),
    ], members).single;
    expect(g.ply, 3);
    expect(g.toMoveUserId, 'B');
  });

  test('failed rows are ignored', () {
    final games = deriveGames([
      game('g0', GameType.chess, 'A', state: 'failed'),
      game('g', GameType.tictactoe, 'A'),
      ttt('A', 'g', 0, 0, state: 'failed'),
      ttt('A', 'g', 0, 4),
    ], members);
    expect(games.map((g) => g.id), ['g']);
    expect(games.single.ply, 1);
    expect(games.single.board.play({'cell': 0}), isNotNull);
  });

  test('undecodable bodies are ignored', () {
    MessageRow broken(String kind, String? body) => MessageRow(
      id: 'x$kind',
      chatId: 'c',
      seq: 999,
      senderUserId: 'A',
      senderDeviceId: 'A-d',
      kind: kind,
      body: body,
      targetId: 'g',
      envelope: null,
      createdAt: 0,
      state: 'sent',
    );
    final g = deriveGames([
      game('g', GameType.tictactoe, 'A'),
      broken('game', null),
      broken('game', 'not json'),
      broken('move', '{"kind":"text","text":"hi"}'),
      broken('move', '{"kind":"move","target":"g"}'),
    ], members).single;
    expect(g.ply, 0);
  });

  test('moves after the outcome are ignored', () {
    final g = deriveGames([
      game('g', GameType.tictactoe, 'A'),
      ttt('A', 'g', 0, 0),
      ttt('B', 'g', 1, 3),
      ttt('A', 'g', 2, 1),
      ttt('B', 'g', 3, 4),
      ttt('A', 'g', 4, 2),
      ttt('B', 'g', 5, 5),
      move('B', 'g', GameType.tictactoe, 5, {'type': 'resign'}),
    ], members).single;
    expect(g.outcome!.reason, 'line');
    expect(g.winnerUserId, 'A');
    expect(g.ply, 5);
  });

  test("offerer's own play keeps their offer; opponent can still accept", () {
    final g = deriveGames([
      game('g', GameType.chess, 'A'),
      chess('A', 'g', 0, {'type': 'draw_offer'}),
      uci('A', 'g', 0, 'e2e4'),
      chess('B', 'g', 1, {'type': 'draw_accept'}),
    ], members).single;
    expect(g.ply, 1);
    expect(g.outcome!.winner, isNull);
    expect(g.outcome!.reason, 'agreed');
  });

  test('counter-offer while an offer is pending is ignored', () {
    final g = deriveGames([
      game('g', GameType.chess, 'A'),
      chess('A', 'g', 0, {'type': 'draw_offer'}),
      chess('B', 'g', 0, {'type': 'draw_offer'}),
      chess('A', 'g', 0, {'type': 'draw_accept'}),
    ], members).single;
    expect(g.drawOfferedBy, 'A');
    expect(g.over, isFalse);
  });

  test('games in a group chat are inert even with two members', () {
    final games = deriveGames(
      [game('g', GameType.tictactoe, 'A'), ttt('A', 'g', 0, 0)],
      members,
      direct: false,
    );
    expect(games.single.inert, isTrue);
    expect(games.single.ply, 0);
    expect(activeGame(games), isNull);
  });

  test('resign by a non-player is ignored', () {
    final g = deriveGames([
      game('g', GameType.chess, 'A'),
      chess('C', 'g', 0, {'type': 'resign'}),
    ], members).single;
    expect(g.over, isFalse);
  });

  test('checkers draw offer then accept is a draw', () {
    MessageRow ck(String s, int ply, Map<String, Object?> a) =>
        move(s, 'g', GameType.checkers, ply, a);
    final g = deriveGames([
      game('g', GameType.checkers, 'A'),
      ck('A', 0, {
        'type': 'play',
        'path': [9, 13],
      }),
      ck('B', 1, {'type': 'draw_offer'}),
      ck('A', 1, {'type': 'draw_accept'}),
    ], members).single;
    expect(g.ply, 1);
    expect(g.outcome!.winner, isNull);
    expect(g.outcome!.reason, 'agreed');
  });

  test('a poke leaves the game unchanged', () {
    final g = game('g', GameType.tictactoe, 'A');
    final a = ttt('A', 'g', 0, 4);
    final poke = move('A', 'g', GameType.tictactoe, 1, {'type': 'poke'});
    final before = deriveGames([g, a], members).single;
    final after = deriveGames([g, a, poke], members).single;
    expect(after.ply, before.ply);
    expect(after.toMoveUserId, 'B');
    expect(
      (after.board as TicTacToeBoard).cells,
      (before.board as TicTacToeBoard).cells,
    );
    expect(after.drawOfferedBy, isNull);
  });

  test('playResults holds the state after each applied play only', () {
    final g = game('g', GameType.tictactoe, 'A');
    final p0 = ttt('A', 'g', 0, 0);
    final stale = ttt('B', 'g', 0, 1); // wrong ply
    final illegal = ttt('B', 'g', 1, 0); // taken cell
    final p1 = ttt('B', 'g', 1, 3);
    final resign = move('A', 'g', GameType.tictactoe, 2, {'type': 'resign'});
    final failed = ttt('A', 'g', 2, 1, state: 'failed');
    final results = playResults([
      g,
      p0,
      stale,
      illegal,
      p1,
      failed,
      resign,
    ], members);
    expect(results.keys, unorderedEquals([p0.id, p1.id]));
    expect(results[p0.id]!.ply, 1);
    expect(results[p0.id]!.toMoveUserId, 'B');
    expect(results[p1.id]!.ply, 2);
    expect(results[p1.id]!.over, isFalse);
  });

  test('playResults records the game-ending play', () {
    final rows = [
      game('g', GameType.tictactoe, 'A'),
      ttt('A', 'g', 0, 0),
      ttt('B', 'g', 1, 3),
      ttt('A', 'g', 2, 1),
      ttt('B', 'g', 3, 4),
      ttt('A', 'g', 4, 2),
    ];
    final last = playResults(rows, members)[rows.last.id]!;
    expect(last.over, isTrue);
    expect(last.winnerUserId, 'A');
  });

  test('playResults skips plays of inert games', () {
    final rows = [game('g', GameType.tictactoe, 'A'), ttt('A', 'g', 0, 0)];
    expect(playResults(rows, members, direct: false), isEmpty);
  });
}
