// A poll inside its message bubble (docs/protocol.md "Polls"): the question, each option with a bar,
// the faces of who picked it and a count; tapping an option votes at once.
import 'package:material_ui/material_ui.dart';

import '../../chat/db/chat_db.dart';
import '../../chat/polls.dart';
import '../../theme/motion.dart';
import '../../theme/tokens.dart';
import '../../widgets/person_avatar.dart';

/// Faces shown per option before the count says the rest.
const _maxFaces = 3;

/// The trophy by a winner once the poll has ended.
const _trophy = '🏆';

/// The choices to send when [me] taps option [i] of [state]: single choice moves the vote there (or
/// takes it back when [i] is already the pick), multiple choice toggles [i].
List<int> pollTap(PollState state, String me, int i) {
  final mine = state.mine(me);
  if (!state.poll.multi) return mine.length == 1 && mine.first == i ? const [] : [i];
  return mine.contains(i) ? [for (final c in mine) if (c != i) c] : ([...mine, i]..sort());
}

/// The poll in [row]'s bubble. [onVote] (null: can't vote, e.g. not sent or a read-only chat) sends
/// the new choices; [onEnd] (the creator, while open) ends it after asking.
class PollBubble extends StatelessWidget {
  const PollBubble({
    super.key,
    required this.row,
    required this.state,
    required this.me,
    required this.mine,
    required this.nameOf,
    this.onVote,
    this.onEnd,
    this.onSeeVotes,
  });

  final MessageRow row;
  final PollState state;
  final String? me;

  /// My message: the bubble's own colors.
  final bool mine;

  /// A voter's name, for their face.
  final String Function(String userId) nameOf;
  final ValueChanged<List<int>>? onVote;
  final VoidCallback? onEnd, onSeeVotes;

  Future<void> _confirmEnd(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End poll?'),
        content: const Text("Votes stop counting and the results are final. This can't be undone."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('poll-end-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('End poll'),
          ),
        ],
      ),
    );
    if (ok == true) onEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = FamTokens.of(context);
    final fg = mine ? t.onMineBubble : t.onTheirsBubble;
    final meta = mine ? t.mineMeta : t.theirsMeta;
    final poll = state.poll;
    final ended = state.ended;
    final picked = me == null ? const <int>[] : state.mine(me!);
    final voters = state.votes.length;
    final canVote = !ended && onVote != null && me != null;
    final hint = ended || !canVote
        ? null
        : picked.isEmpty
        ? (poll.multi ? 'Tap to vote, pick as many as you like' : 'Tap to vote')
        : poll.multi
        ? 'You picked ${picked.length}'
        : 'Tap to change';
    final small = theme.textTheme.labelMedium?.copyWith(color: meta);
    final accent = mine ? fg : theme.colorScheme.primary;

    Widget faces(int i) {
      final who = [for (final e in state.votes.entries) if (e.value.contains(i)) e.key];
      if (who.isEmpty) return const SizedBox.shrink();
      final shown = who.take(_maxFaces).toList();
      const r = 9.0, step = 13.0;
      return SizedBox(
        width: r * 2 + step * (shown.length - 1),
        height: r * 2,
        child: Stack(children: [
          for (var k = 0; k < shown.length; k++)
            Positioned(
              left: k * step,
              child: Container(
                key: Key('poll-face-$i-${shown[k]}'),
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: mine ? t.mineBubble : t.theirsBubble, width: 1.5)),
                child: PersonAvatar(label: nameOf(shown[k]), colorKey: shown[k], userId: shown[k], radius: r - 1.5),
              ),
            ),
        ]),
      );
    }

    Widget option(int i) {
      final count = state.counts[i];
      final chosen = picked.contains(i);
      final winner = state.winners.contains(i);
      final share = voters == 0 ? 0.0 : count / voters;
      final mark = ended
          ? null
          : Icon(
              poll.multi
                  ? (chosen ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded)
                  : (chosen ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded),
              size: 20,
              color: chosen ? accent : meta,
            );
      return InkWell(
        key: Key('poll-option-$i'),
        borderRadius: BorderRadius.circular(Radii.xs),
        onTap: canVote ? () => onVote!(pollTap(state, me!, i)) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              if (mark != null) ...[mark, const SizedBox(width: Space.sm)],
              Expanded(
                child: Text(
                  winner ? '${poll.options[i]} $_trophy' : poll.options[i],
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: fg,
                    fontWeight: winner || chosen ? FontWeight.w700 : null,
                  ),
                ),
              ),
              const SizedBox(width: Space.sm),
              faces(i),
              const SizedBox(width: Space.xs),
              SizedBox(
                width: 22,
                child: Text(
                  '$count',
                  key: Key('poll-count-$i'),
                  textAlign: TextAlign.end,
                  style: small?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    fontWeight: winner ? FontWeight.w700 : null,
                    color: winner ? fg : meta,
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 5),
            Padding(
              padding: EdgeInsets.only(left: mark == null ? 0 : 28),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: Stack(children: [
                  Container(height: 5, color: fg.withValues(alpha: 0.12)),
                  AnimatedFractionallySizedBox(
                    duration: Motion.of(context, Motion.medium),
                    curve: Curves.easeOutCubic,
                    widthFactor: share.clamp(0.0, 1.0),
                    child: Container(height: 5, color: winner || !ended ? accent : meta),
                  ),
                ]),
              ),
            ),
          ]),
        ),
      );
    }

    final buttonStyle = TextButton.styleFrom(
      foregroundColor: accent,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: Space.sm),
      minimumSize: const Size(0, 36),
    );
    return SizedBox(
      key: Key('poll-${row.id}'),
      width: 300,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: Space.sm),
            child: Icon(Icons.poll_outlined, size: 18, color: meta),
          ),
          Expanded(
            child: Text(poll.question, style: theme.textTheme.titleSmall?.copyWith(color: fg, fontWeight: FontWeight.w700)),
          ),
          if (ended)
            Container(
              key: const Key('poll-ended'),
              margin: const EdgeInsets.only(left: Space.sm),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                border: Border.all(color: meta),
                borderRadius: BorderRadius.circular(Radii.xs),
              ),
              child: Text('ENDED', style: theme.textTheme.labelSmall?.copyWith(color: meta, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
            ),
        ]),
        const SizedBox(height: 2),
        Text(
          '${poll.multi ? 'Pick one or more' : 'Pick one'} · $voters voted',
          key: const Key('poll-summary'),
          style: small,
        ),
        const SizedBox(height: Space.xs),
        for (var i = 0; i < poll.options.length; i++) option(i),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(hint, style: small?.copyWith(fontStyle: FontStyle.italic)),
          ),
        const SizedBox(height: Space.xs),
        Row(children: [
          TextButton(
            key: const Key('poll-see-votes'),
            style: buttonStyle,
            onPressed: onSeeVotes,
            child: const Text('See votes'),
          ),
          const Spacer(),
          if (onEnd != null && !ended && me == state.creator)
            TextButton(
              key: const Key('poll-end'),
              style: buttonStyle,
              onPressed: () => _confirmEnd(context),
              child: const Text('End poll'),
            ),
        ]),
      ]),
    );
  }
}

/// Who picked each option of [state], then "Hasn't voted:" with the [members] who haven't.
Future<void> showPollVotesSheet(
  BuildContext context, {
  required PollState state,
  required List<MemberRow> members,
  required Map<String, UserRow> users,
  required String? me,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        final theme = Theme.of(context);
        String nameOf(String id) => id == me ? 'You' : users[id]?.name ?? 'Someone';
        Widget heading(String text, {Key? key, String? trailing}) => Padding(
              key: key,
              padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.xs),
              child: Row(children: [
                Expanded(
                  child: Text(text, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ),
                if (trailing != null)
                  Text(trailing, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ]),
            );
        Widget person(String id) => ListTile(
              dense: true,
              leading: PersonAvatar(label: users[id]?.name ?? '?', colorKey: id, userId: id, radius: 16),
              title: Text(nameOf(id)),
            );
        final poll = state.poll;
        final waiting = [for (final m in members) if (!state.votes.containsKey(m.userId)) m.userId]
          ..sort((a, b) => nameOf(a).compareTo(nameOf(b)));
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
            child: ListView(shrinkWrap: true, key: const Key('poll-votes-sheet'), children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.lg, Space.lg, Space.lg, 0),
                child: Text(poll.question, style: theme.textTheme.titleMedium),
              ),
              for (var i = 0; i < poll.options.length; i++) ...[
                heading(
                  state.winners.contains(i) ? '${poll.options[i]} $_trophy' : poll.options[i],
                  key: Key('poll-votes-option-$i'),
                  trailing: '${state.counts[i]}',
                ),
                for (final e in state.votes.entries)
                  if (e.value.contains(i)) person(e.key),
              ],
              if (waiting.isNotEmpty) ...[
                heading("Hasn't voted:", key: const Key('poll-not-voted')),
                for (final id in waiting) person(id),
              ],
              const SizedBox(height: Space.sm),
            ]),
          ),
        );
      },
    );
