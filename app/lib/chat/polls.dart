// Polls (docs/protocol.md "Polls"): a `poll` message plus silent `vote` and `poll_end` events, folded
// per poll in timeline order so every device shows the same totals.
import 'dart:convert';

import 'db/chat_db.dart';
import 'plaintext.dart';

/// A poll with the votes and end that count.
class PollState {
  PollState._(this.poll, this.creator, this.votes, this.ended);

  final PollBody poll;

  /// The poll's sender: the only one whose end counts.
  final String creator;

  /// Voter user id → the option indexes they picked (never empty), ordered by each voter's latest vote.
  final Map<String, List<int>> votes;

  /// Ended by its creator: results are final.
  final bool ended;

  /// Votes per option.
  late final List<int> counts = () {
    final c = List.filled(poll.options.length, 0);
    for (final v in votes.values) {
      for (final i in v) {
        c[i]++;
      }
    }
    return List<int>.unmodifiable(c);
  }();

  /// The options with the top count once ended (ties included); empty while open or with no votes.
  late final Set<int> winners = () {
    if (!ended) return const <int>{};
    final top = counts.fold(0, (a, b) => b > a ? b : a);
    return top == 0 ? const <int>{} : {for (var i = 0; i < counts.length; i++) if (counts[i] == top) i};
  }();

  /// What [me] picked (empty when they haven't voted).
  List<int> mine(String me) => votes[me] ?? const [];
}

/// Poll id → its state, for the polls among [rows]. [rows] in timeline order (as `watchMessages`
/// gives them: by seq, own pending ones last), so every device folds the same events the same way.
/// Failed rows are skipped, and so are events whose target isn't a poll here.
Map<String, PollState> pollStates(Iterable<MessageRow> rows) {
  final polls = <String, (PollBody, String)>{};
  for (final r in rows) {
    if (r.kind != 'poll' || r.state == 'failed') continue;
    final p = _decode(r);
    if (p is PollBody) polls[r.id] = (p, r.senderUserId);
  }
  final votes = {for (final id in polls.keys) id: <String, List<int>>{}};
  final ended = <String>{};
  for (final r in rows) {
    if ((r.kind != 'vote' && r.kind != 'poll_end') || r.state == 'failed' || r.targetId == null) continue;
    final poll = polls[r.targetId!];
    if (poll == null || ended.contains(r.targetId)) continue;
    final (body, creator) = poll;
    final p = _decode(r);
    if (p is PollEndBody && p.target == r.targetId) {
      if (r.senderUserId == creator) ended.add(r.targetId!);
    } else if (p is VoteBody && p.target == r.targetId) {
      final picked = <int>[];
      for (final c in p.choices) {
        if (c < 0 || c >= body.options.length || picked.contains(c)) continue;
        picked.add(c);
        if (!body.multi) break;
      }
      final mine = votes[r.targetId!]!..remove(r.senderUserId);
      if (picked.isNotEmpty) mine[r.senderUserId] = List.unmodifiable(picked);
    }
  }
  return {
    for (final MapEntry(key: id, value: (body, creator)) in polls.entries)
      id: PollState._(body, creator, Map.unmodifiable(votes[id]!), ended.contains(id)),
  };
}

Plaintext? _decode(MessageRow m) {
  if (m.body == null) return null;
  try {
    return Plaintext.decode(utf8.encode(m.body!));
  } on FormatException {
    return null;
  }
}
