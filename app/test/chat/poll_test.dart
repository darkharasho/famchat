import 'dart:convert';

import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/message_changes.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/chat/polls.dart';
import 'package:flutter_test/flutter_test.dart';

Plaintext decode(Map<String, Object?> j) => Plaintext.decode(utf8.encode(jsonEncode(j)));

var _n = 0;

MessageRow row(String sender, Plaintext p, {String? id, String state = 'sent', bool pending = false}) {
  _n++;
  return MessageRow(
    id: id ?? 'm$_n',
    chatId: 'c',
    seq: pending ? null : _n,
    senderUserId: sender,
    senderDeviceId: '$sender-d',
    kind: p.kind,
    body: jsonEncode(p.toJson()),
    targetId: switch (p) {
      VoteBody(:final target) || PollEndBody(:final target) => target,
      _ => null,
    },
    envelope: null,
    createdAt: _n,
    state: pending ? 'pending' : state,
  );
}

const lunch = PollBody('Lunch?', ['Pizza', 'Tacos', 'Soup']);
const multiLunch = PollBody('Lunch?', ['Pizza', 'Tacos', 'Soup'], multi: true);

void main() {
  test('poll, vote and poll_end round-trip', () {
    for (final p in [
      lunch,
      const PollBody('Days?', ['Thu', 'Fri'], multi: true, replyTo: 'r'),
      const VoteBody('p', [0, 2]),
      const VoteBody('p', []),
      const PollEndBody('p'),
    ]) {
      expect(Plaintext.decode(p.encode()).toJson(), p.toJson());
    }
    expect(lunch.toJson(), {'kind': 'poll', 'question': 'Lunch?', 'options': ['Pizza', 'Tacos', 'Soup'], 'multi': false});
    final back = Plaintext.decode(multiLunch.encode()) as PollBody;
    expect(back.multi, isTrue);
    expect(back.options, ['Pizza', 'Tacos', 'Soup']);
    expect((decode({'kind': 'poll', 'question': 'Q', 'options': ['a', 'b']}) as PollBody).multi, isFalse);
    expect((decode({'kind': 'vote', 'target': 'p', 'choices': [1.0]}) as VoteBody).choices, [1]);
  });

  test('every poll limit rejects', () {
    String n(int len) => 'x' * len;
    final ok = decode({'kind': 'poll', 'question': n(maxPollQuestion), 'options': [n(maxPollOption), 'b']});
    expect(ok, isA<PollBody>());
    expect(decode({'kind': 'poll', 'question': 'Q', 'options': List.generate(maxPollOptions, (i) => '$i')}), isA<PollBody>());
    for (final bad in <Map<String, Object?>>[
      {'kind': 'poll', 'options': ['a', 'b']},
      {'kind': 'poll', 'question': '', 'options': ['a', 'b']},
      {'kind': 'poll', 'question': '   ', 'options': ['a', 'b']},
      {'kind': 'poll', 'question': n(maxPollQuestion + 1), 'options': ['a', 'b']},
      {'kind': 'poll', 'question': 'Q'},
      {'kind': 'poll', 'question': 'Q', 'options': ['a']},
      {'kind': 'poll', 'question': 'Q', 'options': List.generate(maxPollOptions + 1, (i) => '$i')},
      {'kind': 'poll', 'question': 'Q', 'options': ['a', '']},
      {'kind': 'poll', 'question': 'Q', 'options': ['a', ' ']},
      {'kind': 'poll', 'question': 'Q', 'options': ['a', n(maxPollOption + 1)]},
      {'kind': 'poll', 'question': 'Q', 'options': ['a', 5]},
      {'kind': 'poll', 'question': 'Q', 'options': ['Pizza', ' pizza ']},
      {'kind': 'poll', 'question': 'Q', 'options': ['a', 'b'], 'multi': 'yes'},
      {'kind': 'vote', 'choices': [0]},
      {'kind': 'vote', 'target': '', 'choices': [0]},
      {'kind': 'vote', 'target': 'p'},
      {'kind': 'vote', 'target': 'p', 'choices': ['0']},
      {'kind': 'vote', 'target': 'p', 'choices': [0.5]},
      {'kind': 'vote', 'target': 'p', 'choices': List.generate(maxPollOptions + 1, (i) => i)},
      {'kind': 'poll_end'},
      {'kind': 'poll_end', 'target': ''},
    ]) {
      expect(() => decode(bad), throwsFormatException, reason: '$bad');
    }
  });

  test('validPoll trims, drops blank options and refuses what receivers would drop', () {
    final p = validPoll('  Lunch? ', ['Pizza ', '', '  ', 'Tacos'], multi: true)!;
    expect(p.question, 'Lunch?');
    expect(p.options, ['Pizza', 'Tacos']);
    expect(p.multi, isTrue);
    expect(validPoll('', ['a', 'b']), isNull);
    expect(validPoll('Q', ['a', '']), isNull);
    expect(validPoll('Q', ['a', 'A']), isNull);
    expect(validPoll('Q', List.generate(maxPollOptions + 1, (i) => '$i')), isNull);
  });

  test("each voter's latest vote wins and [] takes it back", () {
    final rows = [
      row('a', multiLunch, id: 'p'),
      row('b', const VoteBody('p', [0])),
      row('c', const VoteBody('p', [1, 2])),
      row('b', const VoteBody('p', [1])),
      row('d', const VoteBody('p', [2])),
      row('d', const VoteBody('p', [])),
    ];
    final s = pollStates(rows)['p']!;
    expect(s.votes, {'b': [1], 'c': [1, 2]});
    expect(s.counts, [0, 2, 1]);
    expect(s.mine('c'), [1, 2]);
    expect(s.mine('d'), isEmpty);
    expect(s.ended, isFalse);
    expect(s.winners, isEmpty);
    expect(s.creator, 'a');
  });

  test('a single-choice poll counts only the first choice; out-of-range and repeated indexes drop', () {
    final rows = [
      row('a', lunch, id: 'p'),
      row('b', const VoteBody('p', [2, 0])),
      row('c', const VoteBody('p', [7, -1, 1])),
      row('d', const VoteBody('p', [9])),
    ];
    final s = pollStates(rows)['p']!;
    expect(s.votes, {'b': [2], 'c': [1]});
    expect(s.counts, [0, 1, 1]);
    final m = pollStates([row('a', multiLunch, id: 'q'), row('b', const VoteBody('q', [2, 2, 5, 0]))])['q']!;
    expect(m.votes, {'b': [2, 0]});
  });

  test("an end from anyone but the poll's sender changes nothing", () {
    final rows = [
      row('a', lunch, id: 'p'),
      row('b', const VoteBody('p', [0])),
      row('b', const PollEndBody('p')),
      row('c', const VoteBody('p', [1])),
    ];
    final s = pollStates(rows)['p']!;
    expect(s.ended, isFalse);
    expect(s.counts, [1, 1, 0]);
  });

  test('votes after the end are ignored, and winners include ties', () {
    final rows = [
      row('a', lunch, id: 'p'),
      row('b', const VoteBody('p', [0])),
      row('c', const VoteBody('p', [1])),
      row('a', const PollEndBody('p')),
      row('d', const VoteBody('p', [1])),
      row('b', const VoteBody('p', [])),
      row('a', const PollEndBody('p')),
    ];
    final s = pollStates(rows)['p']!;
    expect(s.ended, isTrue);
    expect(s.counts, [1, 1, 0]);
    expect(s.winners, {0, 1});
    final empty = pollStates([row('a', lunch, id: 'q'), row('a', const PollEndBody('q'))])['q']!;
    expect(empty.ended, isTrue);
    expect(empty.winners, isEmpty);
  });

  test('an own pending vote applies after every stored one', () {
    final pending = row('me', const VoteBody('p', [2]), pending: true);
    final rows = [
      row('a', lunch, id: 'p'),
      row('me', const VoteBody('p', [0])),
      row('b', const VoteBody('p', [1])),
      pending,
    ];
    final s = pollStates(rows)['p']!;
    expect(s.mine('me'), [2]);
    expect(s.counts, [0, 1, 1]);
    // Pending after an end: it won't count once stored either.
    final ended = pollStates([row('a', lunch, id: 'q'), row('a', const PollEndBody('q')), row('me', const VoteBody('q', [0]), pending: true)])['q']!;
    expect(ended.votes, isEmpty);
  });

  test('failed votes and ends, and votes for something that is not a poll, are ignored', () {
    final rows = [
      row('a', lunch, id: 'p'),
      row('a', const TextBody('hi'), id: 't'),
      row('b', const VoteBody('p', [0]), state: 'failed'),
      row('a', const PollEndBody('p'), state: 'failed'),
      row('b', const VoteBody('t', [0])),
      row('b', const VoteBody('missing', [0])),
    ];
    final states = pollStates(rows);
    expect(states.keys, ['p']);
    expect(states['p']!.votes, isEmpty);
    expect(states['p']!.ended, isFalse);
  });

  test('votes and ends are silent changes hidden from the timeline', () {
    expect(changeKinds, containsAll(['vote', 'poll_end']));
    expect(timelineHiddenKinds, containsAll(['vote', 'poll_end']));
    expect(changeKinds.contains('poll'), isFalse);
  });
}
