import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/chat/providers.dart';
import 'package:famchat/games/checkers.dart';
import 'package:famchat/games/chess_board.dart';
import 'package:famchat/games/game_state.dart';
import 'package:famchat/games/go_fish.dart';
import 'package:famchat/games/landlord/landlord.dart';
import 'package:famchat/games/providers.dart';
import 'package:famchat/games/rules.dart';
import 'package:famchat/games/tictactoe.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'landlord/helpers.dart';

/// Everything a [GameState] shows, so two states can be compared.
String fingerprint(GameState g) {
  final b = g.board;
  final squares = switch (b) {
    TicTacToeBoard() => b.cells.map((c) => c?.name ?? '-').join(),
    CheckersBoard() => [
      for (var i = 0; i < 32; i++)
        '${b.at(i)?.side.name}${b.at(i)?.piece.name}',
    ].join(','),
    ChessBoard() => [
      for (final f in 'abcdefgh'.split(''))
        for (var r = 1; r <= 8; r++)
          '${b.at('$f$r')?.side.name}${b.at('$f$r')?.role.name}',
    ].join(','),
    GoFishBoard() => [
      b.hand(Side.first),
      b.hand(Side.second),
      b.books(Side.first),
      b.books(Side.second),
      b.stockCount,
    ].join(','),
    LandlordBoard() => [
      for (final s in Side.values) ...[b.cash(s), b.position(s)],
      for (var i = 0; i < 40; i++) '${b.owner(i)?.name}${b.level(i)}${b.isMortgaged(i)}',
      b.phase,
      b.events.length,
    ].join(','),
    _ => '?',
  };
  return [
    g.id,
    g.type,
    g.firstUserId,
    g.secondUserId,
    g.ply,
    g.outcome?.winner,
    g.outcome?.reason,
    g.drawOfferedBy,
    g.inert,
    g.startedSeq,
    b.toMove,
    squares,
  ].join('|');
}

List<String> prints(List<GameState> games) => [
  for (final g in games) fingerprint(g),
];

/// A message as the local db holds it.
class _Msg {
  _Msg(this.id, this.sender, this.body) : kind = body.kind;

  final String id, sender, kind;
  final Plaintext body;
  int? seq;
  String state = 'pending';

  MessageRow get row => MessageRow(
    id: id,
    chatId: 'c',
    seq: seq,
    senderUserId: sender,
    senderDeviceId: '$sender-d',
    kind: kind,
    body: jsonEncode(body.toJson()),
    targetId: body is MoveBody ? (body as MoveBody).target : null,
    envelope: null,
    createdAt: 0,
    state: state,
  );
}

/// `watchMessages` order: seq ascending, then pending and failed rows.
List<MessageRow> _ordered(List<_Msg> msgs) => [
  ...(msgs.where((m) => m.seq != null).toList()
        ..sort((a, b) => a.seq!.compareTo(b.seq!)))
      .map((m) => m.row),
  ...msgs.where((m) => m.seq == null).map((m) => m.row),
];

/// A random legal-ish play for [g], or a junk one.
Map<String, Object?> randomPlay(Random rnd, GameState g) {
  final b = g.board;
  switch (b) {
    case TicTacToeBoard():
      return {'type': 'play', 'cell': rnd.nextInt(9)};
    case CheckersBoard():
      final legal = b.legalPaths();
      if (legal.isEmpty) {
        return {
          'type': 'play',
          'path': const [0, 4],
        };
      }
      return {'type': 'play', 'path': legal[rnd.nextInt(legal.length)]};
    case ChessBoard():
      final plays = <String>[];
      for (final f in 'abcdefgh'.split('')) {
        for (var r = 1; r <= 8; r++) {
          final from = '$f$r';
          for (final to in b.targetsFrom(from)) {
            plays.add('$from$to${b.needsPromotion(from, to) ? 'q' : ''}');
          }
        }
      }
      if (plays.isEmpty) return {'type': 'play', 'uci': 'e2e4'};
      return {'type': 'play', 'uci': plays[rnd.nextInt(plays.length)]};
  }
  if (b is GoFishBoard) {
    final hand = b.hand(b.toMove);
    if (hand.isEmpty) return {'type': 'play', 'rank': 1};
    return {'type': 'play', 'rank': GoFishBoard.rankOf(hand[rnd.nextInt(hand.length)])};
  }
  if (b is LandlordBoard) {
    final a = randomLandlordAction(rnd, b);
    return {'type': 'play', ...?a};
  }
  return {'type': 'play'};
}

void main() {
  test('cached derive equals a fresh replay over random histories', () {
    for (var seed = 0; seed < 40; seed++) {
      final rnd = Random(seed);
      final cache = GameCache();
      final msgs = <_Msg>[];
      var seq = 0, n = 0;
      var members = ['A', 'B'];
      var direct = true;
      for (var step = 0; step < 120; step++) {
        final pending = msgs.where((m) => m.state == 'pending').toList();
        final games = deriveGames(_ordered(msgs), members, direct: direct);
        final roll = rnd.nextInt(100);
        if (roll < 8 || games.isEmpty) {
          final t = GameType.values[rnd.nextInt(GameType.values.length)];
          final first = rnd.nextBool() ? 'A' : 'B';
          // Seeded games usually get a seed; sometimes not (inert).
          final seed = t.seeded && rnd.nextInt(6) != 0 ? rnd.nextInt(1 << 32) : null;
          msgs.add(_Msg('g${n++}', first, GameBody(t, first, seed: seed)));
        } else if (roll < 60) {
          final g = rnd.nextInt(4) == 0
              ? games[rnd.nextInt(games.length)]
              : games.last;
          final turn = g.toMoveUserId ?? 'A';
          final sender = rnd.nextInt(8) == 0 ? (turn == 'A' ? 'B' : 'A') : turn;
          final ply = rnd.nextInt(8) == 0 ? g.ply + 1 : g.ply;
          final a = rnd.nextInt(30);
          final action = a == 0
              ? {'type': 'resign'}
              : a < 3
              ? {'type': 'draw_offer'}
              : a < 5
              ? {'type': 'draw_accept'}
              : a < 6
              ? {'type': 'draw_decline'}
              : randomPlay(rnd, g);
          msgs.add(
            _Msg('m${n++}', sender, MoveBody(g.id, g.type, ply, action)),
          );
        } else if (roll < 85 && pending.isNotEmpty) {
          // The oldest pending row is acknowledged; sometimes another device's
          // row lands first.
          if (rnd.nextInt(5) == 0) {
            final other = _Msg(
              'x${n++}',
              'B',
              Plaintext.decode(utf8.encode(pending.last.row.body!)),
            );
            other
              ..seq = ++seq
              ..state = 'sent';
            msgs.add(other);
          }
          pending.first
            ..seq = ++seq
            ..state = 'sent';
        } else if (roll < 90 && pending.isNotEmpty) {
          pending[rnd.nextInt(pending.length)].state = 'failed';
        } else if (roll < 92) {
          members = members.length == 2 ? ['A', 'B', 'C'] : ['A', 'B'];
        } else if (roll < 93) {
          direct = !direct;
        }
        final rows = _ordered(msgs);
        expect(
          prints(cache.derive(rows, members, direct: direct)),
          prints(deriveGames(rows, members, direct: direct)),
          reason: 'seed $seed step $step',
        );
      }
    }
  });

  test('a quick game during Landlord, then a second quick game: only that one is inert', () {
    final steps = [
      _Msg('l', 'A', const GameBody(GameType.landlord, 'A', seed: 5)),
      _Msg('c', 'B', const GameBody(GameType.chess, 'B')),
      _Msg('m1', 'A', const MoveBody('l', GameType.landlord, 0, {'type': 'play', 'a': 'roll'})),
      _Msg('k', 'A', const GameBody(GameType.checkers, 'A')),
      _Msg('m2', 'B', const MoveBody('c', GameType.chess, 0, {'type': 'play', 'uci': 'e2e4'})),
      _Msg('m3', 'A', const MoveBody('c', GameType.chess, 1, {'type': 'resign'})),
      _Msg('k2', 'B', const GameBody(GameType.checkers, 'B')),
    ];
    final msgs = <_Msg>[];
    final cache = GameCache();
    var seq = 0;
    for (final m in steps) {
      msgs.add(m); // pending first
      expect(prints(cache.derive(_ordered(msgs), ['A', 'B'])), prints(deriveGames(_ordered(msgs), ['A', 'B'])));
      m
        ..seq = ++seq
        ..state = 'sent';
      expect(prints(cache.derive(_ordered(msgs), ['A', 'B'])), prints(deriveGames(_ordered(msgs), ['A', 'B'])));
    }
    final games = cache.derive(_ordered(msgs), ['A', 'B']);
    expect({for (final g in games) g.id: g.inert}, {'l': false, 'c': false, 'k': true, 'k2': false});
  });

  test('a finished game keeps its state object across emissions', () {
    final msgs = [
      _Msg('g1', 'A', const GameBody(GameType.tictactoe, 'A')),
      for (final (i, c) in [0, 3, 1, 4, 2].indexed)
        _Msg(
          'm$i',
          i.isEven ? 'A' : 'B',
          MoveBody('g1', GameType.tictactoe, i, {'type': 'play', 'cell': c}),
        ),
    ];
    var seq = 0;
    for (final m in msgs) {
      m
        ..seq = ++seq
        ..state = 'sent';
    }
    final cache = GameCache();
    final before = cache.derive(_ordered(msgs), ['A', 'B']).single;
    expect(before.over, isTrue);
    final applied = cache.applied;
    // A new game starts and a move is pending: the finished one isn't
    // replayed.
    msgs
      ..add(
        _Msg('g2', 'B', const GameBody(GameType.chess, 'B'))
          ..seq = ++seq
          ..state = 'sent',
      )
      ..add(
        _Msg(
          'm9',
          'B',
          MoveBody('g2', GameType.chess, 0, const {
            'type': 'play',
            'uci': 'e2e4',
          }),
        ),
      );
    final after = cache.derive(_ordered(msgs), ['A', 'B']);
    expect(after.first, same(before));
    expect(after.last.ply, 1);
    expect(cache.applied, applied + 1);
    // The pending move is acknowledged: nothing is replayed.
    msgs.last
      ..seq = ++seq
      ..state = 'sent';
    final acked = cache.derive(_ordered(msgs), ['A', 'B']);
    expect(acked.first, same(before));
    expect(acked.last, same(after.last));
    expect(cache.applied, applied + 1);
  });

  test('an unrelated chat row change does not re-derive', () async {
    final chats = StreamController<ChatRow?>.broadcast();
    ChatRow chat(String? draft) => ChatRow(
      id: 'c',
      kind: 'direct',
      createdBy: 'A',
      currentEpoch: 1,
      epochReady: true,
      lastSeq: 1,
      createdAt: 0,
      myLastReadSeq: 0,
      syncedSeq: 0,
      draft: draft,
    );
    final g = _Msg('g1', 'A', const GameBody(GameType.chess, 'A'))
      ..seq = 1
      ..state = 'sent';
    final container = ProviderContainer(
      overrides: [
        chatProvider.overrideWith((ref, id) => chats.stream),
        messagesProvider.overrideWith((ref, id) => Stream.value([g.row])),
        membersProvider.overrideWith(
          (ref, id) => Stream.value([
            for (final u in ['A', 'B'])
              MemberRow(chatId: 'c', userId: u, joinedSeq: 0, lastReadSeq: 0),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(gamesProvider('c'), (_, _) {});
    addTearDown(sub.close);
    await container.read(messagesProvider('c').future);
    await container.read(membersProvider('c').future);
    chats.add(chat(null));
    await pumpEventQueue();
    final games = container.read(gamesProvider('c'));
    expect(games.single.id, 'g1');
    final cache = container.read(gameCacheProvider('c'));
    final derives = cache.derives;
    chats.add(chat('hello'));
    await pumpEventQueue();
    expect(container.read(gamesProvider('c')), same(games));
    expect(cache.derives, derives);
  });
}
