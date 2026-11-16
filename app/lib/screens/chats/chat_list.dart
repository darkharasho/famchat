import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/db/chat_db.dart';
import '../../chat/providers.dart';
import '../../session/session_controller.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/brand_mark.dart';
import '../../widgets/common.dart';
import '../../widgets/person_avatar.dart';

/// Chats by latest activity, with unread counts and presence.
class ChatList extends ConsumerWidget {
  const ChatList({super.key, this.selectedId});

  final String? selectedId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chats = ref.watch(chatListProvider);
    final users = ref.watch(usersProvider).value ?? const {};
    final online = ref.watch(onlineProvider).value ?? const {};
    final me = ref.watch(myUserIdProvider);
    final items = chats.value;
    if (items == null) return const Center(child: CircularProgressIndicator());
    if (items.isEmpty) {
      final session = ref.watch(sessionProvider);
      final name = session is SignedIn ? session.session.name : null;
      return EmptyState(
        art: const BrandMark(size: 72),
        title: name == null ? 'Hi' : 'Hi, $name',
        body: 'No chats yet',
        action: FilledButton.icon(
          onPressed: () => context.go('/new'),
          icon: const Icon(Icons.add_comment_outlined),
          label: const Text('New chat'),
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.only(top: Space.xs, bottom: Space.xs + MediaQuery.paddingOf(context).bottom),
      itemCount: items.length,
      itemBuilder: (context, i) => _ChatTile(
        item: items[i],
        users: users,
        online: online,
        me: me,
        selected: items[i].chat.id == selectedId,
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  const _ChatTile({required this.item, required this.users, required this.online, required this.me, required this.selected});

  final ChatListItem item;
  final Map<String, UserRow> users;
  final Set<String> online;
  final String? me;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final t = FamTokens.of(context);
    final title = chatTitle(item.chat, item.members, users, me);
    final other = otherMember(item.chat, item.members, me);
    final group = item.chat.kind == 'group';
    final unread = item.unread > 0;
    final changed = item.members.any((m) {
      final u = users[m.userId];
      return m.userId != me && u != null && u.identityPub != u.trustedIdentityPub;
    });
    final tileColor = selected ? theme.listTileTheme.selectedTileColor : null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 1),
      child: Material(
        color: tileColor ?? Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.md),
          onTap: () => context.go('/chats/${item.chat.id}'),
          child: Semantics(
            selected: selected,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 10),
              child: Row(children: [
                PersonAvatar(
                  label: title,
                  colorKey: group ? item.chat.id : (other ?? item.chat.id),
                  group: group,
                  online: other != null && online.contains(other),
                  radius: 26,
                  ringColor: tileColor == null ? s.surface : Color.alphaBlend(tileColor, s.surface),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                      Expanded(
                        child: Row(children: [
                          Flexible(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium?.copyWith(fontWeight: unread ? FontWeight.w700 : FontWeight.w600),
                            ),
                          ),
                          if (changed) ...[
                            const SizedBox(width: 4),
                            Icon(Icons.gpp_maybe_outlined, size: 16, color: s.error, semanticLabel: 'Security key changed'),
                          ],
                        ]),
                      ),
                      const SizedBox(width: Space.sm),
                      Text(
                        shortTime(DateTime.fromMillisecondsSinceEpoch(item.activity)),
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontFamily: kDisplayFont, // plain zeros in times
                          fontSize: 13,
                          color: unread ? s.onSurface : s.onSurfaceVariant,
                          fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ]),
                    const SizedBox(height: 2),
                    Row(children: [
                      Expanded(
                        child: Text(
                          preview(item.last, users, me),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: unread ? s.onSurface : s.onSurfaceVariant,
                            fontWeight: unread ? FontWeight.w500 : null,
                          ),
                        ),
                      ),
                      if (unread) ...[
                        const SizedBox(width: Space.sm),
                        Container(
                          constraints: const BoxConstraints(minWidth: 22),
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(color: t.badge, borderRadius: BorderRadius.circular(99)),
                          child: Semantics(
                            label: '${item.unread} unread',
                            excludeSemantics: true,
                            child: Text(
                              '${item.unread}',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.labelSmall?.copyWith(color: t.onBadge, fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                      ],
                    ]),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// One line about a message for the chat list.
String preview(MessageRow? m, Map<String, UserRow> users, String? me) {
  if (m == null) return 'No messages yet';
  final who = m.senderUserId == me ? 'You: ' : '';
  return switch (m.kind) {
    'text' => '$who${(jsonDecode(m.body!) as Map)['text']}',
    'photo' => '$who📷 Photo',
    'voice' => '$who🎤 Voice message',
    'undecryptable' => 'Waiting for this message…',
    'invalid' => "Message couldn't be verified",
    _ => 'Unsupported message',
  };
}

/// "14:05".
String clockTime(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// "14:05" today, "Mon" this week, else "3/14".
String shortTime(DateTime t, [DateTime? now]) {
  final n = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  if (t.year == n.year && t.month == n.month && t.day == n.day) return '${two(t.hour)}:${two(t.minute)}';
  if (n.difference(t).inDays < 7 && !t.isAfter(n)) {
    return const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][t.weekday - 1];
  }
  return '${t.month}/${t.day}';
}
