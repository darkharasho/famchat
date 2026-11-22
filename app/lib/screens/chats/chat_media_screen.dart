// A chat's photos and videos, links and my starred messages (chat info → "Media, links and
// starred"). Everything comes from this device: the server only has ciphertext.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/db/chat_db.dart';
import '../../chat/message_changes.dart';
import '../../chat/plaintext.dart';
import '../../chat/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/link_text.dart';
import 'album_grid.dart' show AlbumTile;
import 'chat_list.dart' show messageSnippet, shortTime;
import 'media_pager.dart';

/// "This week", "Earlier this month", "October" (this year) or "October 2025".
String galleryGroup(DateTime t, DateTime now) {
  final day = DateTime(t.year, t.month, t.day), today = DateTime(now.year, now.month, now.day);
  if (today.difference(day).inDays < 7) return 'This week';
  if (t.year == now.year && t.month == now.month) return 'Earlier this month';
  const months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  return t.year == now.year ? months[t.month - 1] : '${months[t.month - 1]} ${t.year}';
}

class ChatMediaScreen extends ConsumerWidget {
  const ChatMediaScreen({super.key, required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messages = ref.watch(messagesProvider(chatId)).value ?? const <MessageRow>[];
    final changes = messageChanges(messages);
    final title = ref.watch(chatTitleProvider(chatId));
    // Newest first.
    final media = [
      for (final m in messages.reversed)
        if (captionKinds.contains(m.kind) && !changes.isDeleted(m.id) && m.body != null) m,
    ];
    final links = [
      for (final m in messages.reversed)
        if (!changes.isDeleted(m.id))
          if (changes.textOf(m) case final text?)
            if (splitLinks(text).where((p) => p.uri != null).firstOrNull case final link?) (m, link.uri!, changes.previewOf(m)),
    ];
    final starred = [
      for (final m in ref.watch(starredMessagesProvider(chatId)).value ?? const <MessageRow>[])
        if (!changes.isDeleted(m.id)) m,
    ];
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/chats/$chatId/info')),
          title: Text(title ?? 'Chat'),
          bottom: const TabBar(tabs: [
            Tab(key: Key('media-tab'), text: 'Media'),
            Tab(key: Key('links-tab'), text: 'Links'),
            Tab(key: Key('starred-tab'), text: 'Starred'),
          ]),
        ),
        body: TabBarView(children: [
          _MediaGrid(media: media),
          _LinkList(links: links),
          StarredList(messages: starred, changesOf: (_) => changes, showChat: false),
        ]),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 40, color: s.onSurfaceVariant),
        const SizedBox(height: Space.sm),
        Text(text, style: TextStyle(color: s.onSurfaceVariant)),
      ]),
    );
  }
}

class _MediaGrid extends StatelessWidget {
  const _MediaGrid({required this.media});
  final List<MessageRow> media;

  @override
  Widget build(BuildContext context) {
    if (media.isEmpty) return const _Empty(Icons.photo_library_outlined, 'No photos or videos yet');
    final now = DateTime.now();
    final groups = <(String, List<int>)>[];
    for (final (i, m) in media.indexed) {
      final g = galleryGroup(DateTime.fromMillisecondsSinceEpoch(m.createdAt), now);
      if (groups.isEmpty || groups.last.$1 != g) groups.add((g, []));
      groups.last.$2.add(i);
    }
    final theme = Theme.of(context);
    return CustomScrollView(slivers: [
      for (final (label, indexes) in groups) ...[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.md, Space.lg, Space.md, Space.sm),
            child: Text(label.toUpperCase(),
                style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
          ),
        ),
        SliverGrid(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 160,
            mainAxisSpacing: 2,
            crossAxisSpacing: 2,
          ),
          delegate: SliverChildBuilderDelegate(
            childCount: indexes.length,
            (context, k) {
              final i = indexes[k];
              return LayoutBuilder(
                builder: (context, c) => AlbumTile(
                  key: Key('gallery-${media[i].id}'),
                  row: media[i],
                  size: Size(c.maxWidth, c.maxWidth),
                  onOpen: () => showMediaPager(context, media, i),
                ),
              );
            },
          ),
        ),
      ],
    ]);
  }
}

class _LinkList extends StatelessWidget {
  const _LinkList({required this.links});
  final List<(MessageRow, Uri, LinkPreview?)> links;

  @override
  Widget build(BuildContext context) {
    if (links.isEmpty) return const _Empty(Icons.link_rounded, 'No links yet');
    final h24 = MediaQuery.alwaysUse24HourFormatOf(context);
    return ListView.separated(
      itemCount: links.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final (m, uri, preview) = links[i];
        return ListTile(
          key: Key('link-${m.id}'),
          leading: const Icon(Icons.link_rounded),
          title: Text(preview?.title ?? uri.toString(), maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${preview?.siteName ?? uri.host} · ${shortTime(DateTime.fromMillisecondsSinceEpoch(m.createdAt), h24: h24)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => openLink(uri),
          onLongPress: () => context.go('/chats/${m.chatId}?m=${m.id}'),
        );
      },
    );
  }
}

/// Starred messages, newest star first; tapping one opens it in its chat. [showChat]: say which chat
/// (the list across all chats).
class StarredList extends ConsumerWidget {
  const StarredList({super.key, required this.messages, required this.changesOf, this.showChat = true});

  final List<MessageRow> messages;
  /// The changes (edits, deletes) of the chat a message is in.
  final MessageChanges Function(MessageRow m) changesOf;
  final bool showChat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (messages.isEmpty) return const _Empty(Icons.star_outline_rounded, 'Long-press a message to star it');
    final users = ref.watch(usersProvider).value ?? const {};
    final me = ref.watch(myUserIdProvider);
    final h24 = MediaQuery.alwaysUse24HourFormatOf(context);
    return ListView.separated(
      itemCount: messages.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final m = messages[i];
        final who = m.senderUserId == me ? 'You' : users[m.senderUserId]?.name ?? 'Someone';
        final chat = showChat ? ref.watch(chatTitleProvider(m.chatId)) : null;
        return ListTile(
          key: Key('starred-${m.id}'),
          leading: const Icon(Icons.star_rounded, color: Color(0xFFE0A100)),
          title: Text(messageSnippet(m, changesOf(m)), maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [who, ?chat, shortTime(DateTime.fromMillisecondsSinceEpoch(m.createdAt), h24: h24)].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => context.go('/chats/${m.chatId}?m=${m.id}'),
        );
      },
    );
  }
}
