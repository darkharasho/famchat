import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/db/chat_db.dart';
import '../../chat/providers.dart';
import '../../session/session_controller.dart';

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
      final theme = Theme.of(context);
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(name == null ? 'Hi' : 'Hi, $name', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 12),
            Icon(Icons.forum_outlined, size: 48, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text('No chats yet', style: theme.textTheme.bodyLarge),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => context.go('/new'),
              icon: const Icon(Icons.edit_outlined),
              label: const Text('New chat'),
            ),
          ]),
        ),
      );
    }
    return ListView.builder(
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
    final title = chatTitle(item.chat, item.members, users, me);
    final other = otherMember(item.chat, item.members, me);
    final changed = item.members.any((m) {
      final u = users[m.userId];
      return m.userId != me && u != null && u.identityPub != u.trustedIdentityPub;
    });
    return ListTile(
      selected: selected,
      leading: ChatAvatar(
        label: title,
        group: item.chat.kind == 'group',
        online: other != null && online.contains(other),
      ),
      title: Row(children: [
        Flexible(child: Text(title, overflow: TextOverflow.ellipsis)),
        if (changed) ...[
          const SizedBox(width: 4),
          Icon(Icons.gpp_maybe_outlined, size: 16, color: theme.colorScheme.error, semanticLabel: 'Security key changed'),
        ],
      ]),
      subtitle: Text(preview(item.last, users, me), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(shortTime(DateTime.fromMillisecondsSinceEpoch(item.activity)), style: theme.textTheme.labelSmall),
          if (item.unread > 0) ...[
            const SizedBox(height: 4),
            Badge(label: Text('${item.unread}')),
          ],
        ],
      ),
      onTap: () => context.go('/chats/${item.chat.id}'),
    );
  }
}

/// A round avatar with the name's initial (or a group icon) and an optional presence dot.
class ChatAvatar extends StatelessWidget {
  const ChatAvatar({super.key, required this.label, this.group = false, this.online = false, this.radius = 20});

  final String label;
  final bool group, online;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = label.trim().isEmpty ? '?' : label.trim().characters.first.toUpperCase();
    return Stack(clipBehavior: Clip.none, children: [
      CircleAvatar(
        radius: radius,
        backgroundColor: group ? scheme.tertiaryContainer : scheme.primaryContainer,
        child: group ? const Icon(Icons.group_outlined) : Text(initial),
      ),
      if (online)
        Positioned(
          right: -1,
          bottom: -1,
          child: Container(
            key: const Key('presence-dot'),
            width: radius * 0.6,
            height: radius * 0.6,
            decoration: BoxDecoration(
              color: Colors.green,
              shape: BoxShape.circle,
              border: Border.all(color: scheme.surface, width: 2),
            ),
          ),
        ),
    ]);
  }
}

/// One line about a message for the chat list.
String preview(MessageRow? m, Map<String, UserRow> users, String? me) {
  if (m == null) return 'No messages yet';
  final who = m.senderUserId == me ? 'You: ' : '';
  return switch (m.kind) {
    'text' => '$who${(jsonDecode(m.body!) as Map)['text']}',
    'undecryptable' => 'Waiting for this message…',
    'invalid' => "Message couldn't be verified",
    _ => 'Unsupported message',
  };
}

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
