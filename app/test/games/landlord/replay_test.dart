import 'dart:convert';
import 'dart:math';

import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/games/game_state.dart';
import 'package:famchat/games/landlord/landlord.dart';
import 'package:famchat/games/rules.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

String fp(GameState g) {
  final b = g.board as LandlordBoard;
  return [
    g.ply,
    g.outcome?.reason,
    for (final s in Side.values) ...[b.cash(s), b.position(s), b.inJail(s), b.heldCards(s)],
    for (var i = 0; i < 40; i++) '${b.owner(i)?.name}${b.level(i)}${b.isMortgaged(i)}',
    b.phase,
    b.toMove,
    b.events.length,
  ].join('|');
}

void main() {
  test('400 random actions replay identically through deriveGames and GameCache', () {
    const seed = 20261118;
    final rows = <MessageRow>[];
    var n = 0;
    MessageRow row(String sender, Plaintext p) {
      n++;
      return MessageRow(
        id: 'm$n', chatId: 'c', seq: n, senderUserId: sender, senderDeviceId: 'd', kind: p.kind,
        body: jsonEncode(p.toJson()), targetId: p is MoveBody ? p.target : null,
        envelope: null, createdAt: n, state: 'sent',
      );
    }

    rows.add(row('A', const GameBody(GameType.landlord, 'A', seed: seed)));
    final gameId = rows.first.id;
    final rnd = Random(1);
    final cache = GameCache();
    var board = initialBoard(GameType.landlord, seed) as LandlordBoard;
    var applied = 0;
    for (var i = 0; i < 400 && board.outcome == null; i++) {
      final a = randomLandlordAction(rnd, board);
      if (a == null) break;
      final sender = board.toMove == Side.first ? 'A' : 'B';
      rows.add(row(sender, MoveBody(gameId, GameType.landlord, applied, {'type': 'play', ...a})));
      board = board.play(a)! as LandlordBoard;
      applied++;
      if (i % 50 == 0) {
        expect(fp(cache.derive(rows, ['A', 'B']).single), fp(deriveGames(rows, ['A', 'B']).single));
      }
    }
    final fresh = deriveGames(rows, ['A', 'B']).single;
    expect(fresh.ply, applied);
    expect(fp(cache.derive(rows, ['A', 'B']).single), fp(fresh));
    expect(applied, greaterThanOrEqualTo(100));
    expect(fp(fresh).split('|').skip(1).join('|'), isNotEmpty);
  });
}
