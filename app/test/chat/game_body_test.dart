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
}
