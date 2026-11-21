import 'dart:convert';

import 'package:famchat/chat/message_changes.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/games/rules.dart';
import 'package:flutter_test/flutter_test.dart';

Plaintext decode(Map<String, Object?> j) => Plaintext.decode(utf8.encode(jsonEncode(j)));

void main() {
  test('game round-trips', () {
    const g = GameBody(GameType.chess, 'U1');
    expect(g.toJson(), {'kind': 'game', 'game': 'chess', 'first': 'U1'});
    final back = Plaintext.decode(g.encode()) as GameBody;
    expect(back.game, GameType.chess);
    expect(back.first, 'U1');
  });

  test('a gofish game carries its seed', () {
    const g = GameBody(GameType.gofish, 'U1', seed: 3735928559);
    expect(g.toJson(), {'kind': 'game', 'game': 'gofish', 'first': 'U1', 'seed': 3735928559});
    expect((Plaintext.decode(g.encode()) as GameBody).seed, 3735928559);
    final fromDouble = decode({'kind': 'game', 'game': 'gofish', 'first': 'U1', 'seed': 3735928559.0});
    expect((fromDouble as GameBody).seed, 3735928559);
    expect((decode({'kind': 'game', 'game': 'gofish', 'first': 'U1', 'seed': 0}) as GameBody).seed, 0);
    expect((decode({'kind': 'game', 'game': 'gofish', 'first': 'U1', 'seed': 4294967295}) as GameBody).seed, 4294967295);
  });

  test('a bad or missing seed decodes as null, still a game', () {
    for (final bad in [null, -1, 4294967296, 1.5, '7']) {
      final b = decode({'kind': 'game', 'game': 'gofish', 'first': 'U1', 'seed': bad});
      expect(b, isA<GameBody>(), reason: '$bad');
      expect((b as GameBody).seed, isNull, reason: '$bad');
    }
    expect((decode({'kind': 'game', 'game': 'gofish', 'first': 'U1'}) as GameBody).seed, isNull);
  });

  test('games without a seed send none', () {
    expect(const GameBody(GameType.chess, 'U1').toJson().containsKey('seed'), isFalse);
  });

  test('move round-trips', () {
    const m = MoveBody('G1', GameType.checkers, 3, {
      'type': 'play',
      'path': [9, 14],
    });
    final back = Plaintext.decode(m.encode()) as MoveBody;
    expect(back.target, 'G1');
    expect(back.game, GameType.checkers);
    expect(back.ply, 3);
    expect(back.action, {
      'type': 'play',
      'path': [9, 14],
    });
    expect(back.kind, 'move');
  });

  test('unknown game name decodes to UnknownBody', () {
    expect(decode({'kind': 'game', 'game': 'go', 'first': 'U1'}), isA<UnknownBody>());
    expect(
      decode({
        'kind': 'move',
        'target': 'G',
        'game': 'go',
        'ply': 0,
        'action': {'type': 'play'},
      }),
      isA<UnknownBody>(),
    );
  });

  test('bad game fields are format errors', () {
    expect(() => decode({'kind': 'game', 'game': 'chess'}), throwsFormatException);
    expect(() => decode({'kind': 'game', 'game': 'chess', 'first': ''}), throwsFormatException);
    expect(() => decode({'kind': 'game', 'first': 'U'}), throwsFormatException);
  });

  test('move without ply / negative ply / action without type is a format error', () {
    final ok = {
      'kind': 'move',
      'target': 'G',
      'game': 'chess',
      'ply': 0,
      'action': {'type': 'resign'},
    };
    expect(decode(ok), isA<MoveBody>());
    expect(() => decode({...ok}..remove('ply')), throwsFormatException);
    expect(() => decode({...ok, 'ply': -1}), throwsFormatException);
    expect(() => decode({...ok, 'ply': 1.5}), throwsFormatException);
    expect(() => decode({...ok, 'ply': '1'}), throwsFormatException);
    expect((decode({...ok, 'ply': 2.0}) as MoveBody).ply, 2);
    expect(() => decode({...ok, 'action': <String, Object?>{}}), throwsFormatException);
    expect(() => decode({...ok, 'action': 'resign'}), throwsFormatException);
    expect(() => decode({...ok, 'target': ''}), throwsFormatException);
  });

  test('only moves are hidden from the timeline besides changes', () {
    expect(changeKinds, {'reaction', 'edit', 'delete'});
    expect(timelineHiddenKinds, {'reaction', 'edit', 'delete', 'move'});
  });

  test('war may play to the whole deck', () {
    const g = GameBody(GameType.war, 'U1', seed: 4, wholeDeck: true);
    expect(g.toJson()['until'], 'all_cards');
    expect((Plaintext.decode(g.encode()) as GameBody).wholeDeck, isTrue);
    expect(const GameBody(GameType.gofish, 'U1', seed: 4, wholeDeck: true).toJson().containsKey('until'), isFalse);
    expect((decode({'kind': 'game', 'game': 'gofish', 'first': 'U1', 'seed': 4, 'until': 'all_cards'}) as GameBody).wholeDeck, isFalse);
    expect((decode({'kind': 'game', 'game': 'war', 'first': 'U1', 'seed': 4, 'until': 'all'}) as GameBody).wholeDeck, isFalse);
  });

  test('checkers can carry optional jumps; other games ignore it', () {
    const g = GameBody(GameType.checkers, 'U1', optionalJumps: true);
    expect(g.toJson(), {'kind': 'game', 'game': 'checkers', 'first': 'U1', 'jumps': 'optional'});
    expect((Plaintext.decode(g.encode()) as GameBody).optionalJumps, isTrue);
    expect(const GameBody(GameType.checkers, 'U1').toJson().containsKey('jumps'), isFalse);
    expect(const GameBody(GameType.chess, 'U1', optionalJumps: true).toJson().containsKey('jumps'), isFalse);
    expect((decode({'kind': 'game', 'game': 'chess', 'first': 'U1', 'jumps': 'optional'}) as GameBody).optionalJumps, isFalse);
    expect((decode({'kind': 'game', 'game': 'checkers', 'first': 'U1', 'jumps': 'yes'}) as GameBody).optionalJumps, isFalse);
  });
}
