import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/db/chat_db.dart';
import '../../chat/markdown.dart';
import '../../chat/message_changes.dart';
import '../../chat/files.dart' show fileOf;
import '../../chat/polls.dart' show pollOf;
import '../../chat/providers.dart';
import '../../games/labels.dart';
import '../../push/preview.dart';
import '../../session/session_controller.dart';
import '../sign_out.dart' show apiErrorMessage;
import '../../settings/time_format.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/brand_mark.dart';
import '../../widgets/common.dart';
import '../../widgets/person_avatar.dart';

/// Chats by latest activity (pinned ones first), with unread counts and presence. Archived chats
/// sit behind an "Archived" row at the top.
class ChatList extends ConsumerStatefulWidget {
  const ChatList({super.key, this.selectedId});

  final String? selectedId;

  @override
  ConsumerState<ChatList> createState() => _ChatListState();
}

enum _ChatAction { pin, unpin, markUnread, markRead, archive, unarchive }

class _ChatListState extends ConsumerState<ChatList> {
  bool _showArchived = false;

  Future<void> _act(ChatListItem item, _ChatAction action) async {
    final sync = ref.read(chatSyncProvider);
    if (sync == null) return;
    final id = item.chat.id;
    try {
      switch (action) {
        case _ChatAction.pin || _ChatAction.unpin:
          await sync.pin(id, action == _ChatAction.pin);
        case _ChatAction.markUnread:
          await sync.markUnread(id, true);
        case _ChatAction.markRead:
          await sync.markRead(id);
          if (item.chat.markedUnread) await sync.markUnread(id, false);
        case _ChatAction.archive || _ChatAction.unarchive:
          await sync.archive(id, action == _ChatAction.archive);
          if (mounted) {
            final archived = action == _ChatAction.archive;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(archived ? 'Chat archived' : 'Chat moved out of the archive'),
              action: SnackBarAction(label: 'Undo', onPressed: () => unawaited(sync.archive(id, !archived).catchError((_) {}))),
            ));
          }
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(apiErrorMessage(e))));
    }
  }

  List<(_ChatAction, IconData, String)> _actionsFor(ChatListItem item, bool archived) => [
        item.pinned
            ? (_ChatAction.unpin, Icons.push_pin_outlined, 'Unpin')
            : (_ChatAction.pin, Icons.push_pin_rounded, 'Pin to top'),
        item.looksUnread
            ? (_ChatAction.markRead, Icons.mark_chat_read_outlined, 'Mark as read')
            : (_ChatAction.markUnread, Icons.mark_chat_unread_outlined, 'Mark as unread'),
        archived
            ? (_ChatAction.unarchive, Icons.unarchive_outlined, 'Move out of archive')
            : (_ChatAction.archive, Icons.archive_outlined, 'Archive'),
      ];

  /// Long press: a sheet. Right click: a menu where the pointer is.
  Future<void> _menu(ChatListItem item, bool archived, {Offset? at}) async {
    final actions = _actionsFor(item, archived);
    final _ChatAction? picked;
    if (at != null) {
      final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
      picked = await showMenu<_ChatAction>(
        context: context,
        position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
        items: [
          for (final (a, icon, label) in actions)
            PopupMenuItem(value: a, child: Row(children: [Icon(icon, size: 20), const SizedBox(width: Space.md), Text(label)])),
        ],
      );
    } else {
      picked = await showModalBottomSheet<_ChatAction>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final (a, icon, label) in actions)
              ListTile(key: Key('chat-action-${a.name}'), leading: Icon(icon), title: Text(label), onTap: () => Navigator.pop(context, a)),
          ]),
        ),
      );
    }
    if (picked != null) await _act(item, picked);
  }

  @override
  Widget build(BuildContext context) {
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
    final now = DateTime.now();
    final archived = [for (final i in items) if (i.archivedAt(now)) i];
    final showArchived = _showArchived && archived.isNotEmpty;
    final shown = showArchived ? archived : [for (final i in items) if (!i.archivedAt(now)) i];
    final header = showArchived
        ? _ArchiveHeader(onBack: () => setState(() => _showArchived = false))
        : archived.isEmpty
        ? null
        : _ArchivedRow(
            count: archived.length,
            unread: archived.where((i) => i.looksUnread).length,
            onTap: () => setState(() => _showArchived = true),
          );
    final lead = header == null ? 0 : 1;
    return ListView.builder(
      padding: EdgeInsets.only(top: Space.xs, bottom: Space.xs + MediaQuery.paddingOf(context).bottom),
      itemCount: shown.length + lead,
      itemBuilder: (context, i) {
        if (i < lead) return header!;
        final item = shown[i - lead];
        return _ChatTile(
          item: item,
          users: users,
          online: online,
          me: me,
          selected: item.chat.id == widget.selectedId,
          onMenu: (at) => _menu(item, showArchived, at: at),
        );
      },
    );
  }
}

/// "Archived": opens the archive.
class _ArchivedRow extends StatelessWidget {
  const _ArchivedRow({required this.count, required this.unread, required this.onTap});
  final int count, unread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 1),
      child: ListTile(
        key: const Key('archived-chats'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
        leading: SizedBox(width: 52, child: Icon(Icons.archive_outlined, color: s.onSurfaceVariant)),
        title: Text('Archived', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        trailing: Text(
          unread > 0 ? '$unread unread' : '$count',
          style: theme.textTheme.labelMedium?.copyWith(color: unread > 0 ? s.primary : s.onSurfaceVariant),
        ),
        onTap: onTap,
      ),
    );
  }
}

/// Back out of the archive.
class _ArchiveHeader extends StatelessWidget {
  const _ArchiveHeader({required this.onBack});
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.xs, 0, Space.lg, Space.xs),
      child: Row(children: [
        IconButton(key: const Key('archive-back'), tooltip: 'Back to chats', icon: const Icon(Icons.arrow_back_rounded), onPressed: onBack),
        Expanded(child: Text('Archived', style: theme.textTheme.titleMedium)),
        Flexible(
          child: Text(
            'They come back when a message arrives, unless muted',
            textAlign: TextAlign.end,
            maxLines: 2,
            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ]),
    );
  }
}

class _ChatTile extends StatelessWidget {
  const _ChatTile({
    required this.item,
    required this.users,
    required this.online,
    required this.me,
    required this.selected,
    required this.onMenu,
  });

  /// Opens the chat's menu: at a pointer position (right click), or as a sheet (null).
  final void Function(Offset? at) onMenu;
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
    final unread = item.looksUnread;
    final changed = item.members.any((m) {
      final u = users[m.userId];
      return m.userId != me && u != null && u.identityPub != u.trustedIdentityPub;
    });
    final muted = (item.chat.mutedUntil ?? 0) > DateTime.now().millisecondsSinceEpoch;
    // Shown unless new messages came in since: those are what the person needs to see.
    final draft = unread ? null : item.chat.draft?.replaceAll('\n', ' ');
    final tileColor = selected ? theme.listTileTheme.selectedTileColor : null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 1),
      child: Material(
        color: tileColor ?? Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.md),
          onTap: () => context.go('/chats/${item.chat.id}'),
          onLongPress: () => onMenu(null),
          onSecondaryTapUp: (d) => onMenu(d.globalPosition),
          child: Semantics(
            button: true,
            selected: selected,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 10),
              child: Row(children: [
                PersonAvatar(
                  label: title,
                  colorKey: group ? item.chat.id : (other ?? item.chat.id),
                  userId: group ? null : other,
                  group: group,
                  chatId: item.chat.id,
                  chatPhotoKey: item.chat.avatarKey,
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
                          if (muted) ...[
                            const SizedBox(width: 4),
                            Icon(Icons.notifications_off_outlined, size: 16, color: s.onSurfaceVariant, semanticLabel: 'Muted'),
                          ],
                          if (item.pinned) ...[
                            const SizedBox(width: 4),
                            Icon(Icons.push_pin_rounded, size: 15, color: s.onSurfaceVariant, semanticLabel: 'Pinned'),
                          ],
                        ]),
                      ),
                      const SizedBox(width: Space.sm),
                      Text(
                        shortTime(DateTime.fromMillisecondsSinceEpoch(item.activity), h24: MediaQuery.alwaysUse24HourFormatOf(context)),
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
                        child: draft != null
                            ? Text.rich(
                                TextSpan(children: [
                                  TextSpan(text: 'Draft: ', style: TextStyle(color: s.error, fontWeight: FontWeight.w600)),
                                  TextSpan(text: draft),
                                ]),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(color: s.onSurfaceVariant),
                              )
                            : Text(
                                preview(item.last, users, me, changes: item.lastChanges),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: unread ? s.onSurface : s.onSurfaceVariant,
                                  fontWeight: unread ? FontWeight.w500 : null,
                                ),
                              ),
                      ),
                      if (item.unread == 0 && item.chat.markedUnread) ...[
                        const SizedBox(width: Space.sm),
                        Semantics(
                          label: 'Marked as unread',
                          child: Container(
                            key: const Key('marked-unread-dot'),
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(color: muted ? s.outline : t.badge, shape: BoxShape.circle),
                          ),
                        ),
                      ],
                      if (item.unread > 0) ...[
                        const SizedBox(width: Space.sm),
                        Container(
                          constraints: const BoxConstraints(minWidth: 22),
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(color: muted ? s.outline : t.badge, borderRadius: BorderRadius.circular(99)),
                          child: Semantics(
                            label: '${item.unread} unread',
                            excludeSemantics: true,
                            child: Text(
                              '${item.unread}',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: muted ? s.surface : t.onBadge,
                                fontWeight: FontWeight.w700,
                              ),
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

/// One line about a message for the chat list; [changes] are the edits and deletes over it.
String preview(MessageRow? m, Map<String, UserRow> users, String? me, {List<MessageRow> changes = const []}) {
  if (m == null) return 'No messages yet';
  final who = m.senderUserId == me ? 'You: ' : '';
  final c = messageChanges([m, ...changes]);
  if (c.isDeleted(m.id)) return '${who}Deleted a message';
  return switch (m.kind) {
    'text' || 'photo' || 'voice' || 'gif' || 'video' || 'file' => '$who${messageSnippet(m, c)}',
    'game' || 'move' => '$who${gameListLabel(m) ?? 'Unsupported message'}',
    'poll' => '$who${switch (pollOf(m)) { final p? => pollLabel(p), null => 'Unsupported message' }}',
    'undecryptable' => 'Waiting for this message…',
    'invalid' => "Message couldn't be verified",
    _ => 'Unsupported message',
  };
}

/// A message in a few words (replies, the composer banner, the chat list).
String messageSnippet(MessageRow m, MessageChanges changes) {
  if (changes.isDeleted(m.id)) return 'Deleted message';
  return switch (m.kind) {
    'text' => stripMarkdown(changes.textOf(m) ?? '').replaceAll('\n', ' '),
    'poll' => switch (pollOf(m)) { final p? => '📊 ${p.question.replaceAll('\n', ' ')}', null => 'Message' },
    'file' => switch (fileOf(m)) { final f? => fileLabel(f), null => 'Message' },
    _ => switch (changes.textOf(m)) {
        final caption? => captionLabel(m.kind, caption),
        null => gameListLabel(m) ?? mediaLabel(m.kind) ?? 'Message',
      },
  };
}

/// "14:05" or "2:05 PM" today, "Mon" this week, else "3/14".
String shortTime(DateTime t, {required bool h24, DateTime? now}) {
  final n = now ?? DateTime.now();
  if (t.year == n.year && t.month == n.month && t.day == n.day) return clockTime(t, h24: h24);
  if (n.difference(t).inDays < 7 && !t.isAfter(n)) {
    return const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][t.weekday - 1];
  }
  return '${t.month}/${t.day}';
}
