// Searching people and messages across every chat, or messages in one (`/search?chat=<id>`).
// Messages are searched on this device's decrypted copy, since the server only holds ciphertext.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/db/chat_db.dart';
import '../../chat/providers.dart';
import '../../chat/search.dart';
import '../../theme/tokens.dart';
import '../../widgets/common.dart';
import '../../widgets/person_avatar.dart';
import '../sign_out.dart' show apiErrorMessage;
import 'chat_list.dart' show shortTime;
import 'quick_switcher.dart' show rankChats;

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key, this.chatId});

  /// Only this chat, or every chat when null.
  final String? chatId;

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _field = TextEditingController();
  Timer? _debounce;
  String _query = '';
  List<SearchHit> _hits = const [];

  /// Bumped per search, so a slow earlier one can't overwrite a newer result.
  int _run = 0;

  @override
  void initState() {
    super.initState();
    _field.addListener(() {
      if (_field.text.trim() == _query) return;
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 150), _search);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _field.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _field.text.trim();
    final run = ++_run;
    final hits = await searchMessages(ref.read(chatDbProvider), q, chatId: widget.chatId);
    if (!mounted || run != _run) return;
    setState(() {
      _query = q;
      _hits = hits;
    });
  }

  /// Opens (or starts) the direct chat with [userId].
  Future<void> _openPerson(String userId) async {
    final sync = ref.read(chatSyncProvider);
    if (sync == null) return;
    try {
      final id = await sync.openDirect(userId);
      if (mounted) context.go('/chats/$id');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(apiErrorMessage(e))));
    }
  }

  void _close() => context.go(widget.chatId == null ? '/' : '/chats/${widget.chatId}');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final users = ref.watch(usersProvider).value ?? const <String, UserRow>{};
    final me = ref.watch(myUserIdProvider);
    final items = ref.watch(chatListProvider).value ?? const <ChatListItem>[];
    final chats = {for (final i in items) i.chat.id: i};
    final scoped = widget.chatId == null ? null : chats[widget.chatId];
    final scopeTitle = scoped == null ? null : chatTitle(scoped.chat, scoped.members, users, me);
    String nameOf(String userId) => userId == me ? 'You' : users[userId]?.name ?? 'Someone';

    // Across every chat, people come first: matching family members (not yourself).
    final people = widget.chatId != null || _query.isEmpty
        ? const <UserRow>[]
        : rankChats(
            _query,
            [for (final u in users.values) if (u.id != me && u.deleted != true && u.former != true) u]
              ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())),
            (UserRow u) => u.name,
          ).take(5).toList();

    Widget heading(String text) => ContentWidth(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.xs),
            child: Text(text, style: theme.textTheme.labelLarge?.copyWith(color: s.onSurfaceVariant)),
          ),
        );

    Widget person(UserRow u) => ContentWidth(
          child: ListTile(
            key: Key('search-person-${u.id}'),
            leading: PersonAvatar(label: u.name, colorKey: u.id, userId: u.id, radius: 20),
            title: _Highlighted(u.name, _query, strongBase: true),
            onTap: () => _openPerson(u.id),
          ),
        );

    Widget hit(SearchHit h) {
      final m = h.message;
      final item = chats[m.chatId];
      final where = item == null ? null : chatTitle(item.chat, item.members, users, me);
      final group = item?.chat.kind == 'group';
      // In one chat: who said it. Across chats: the chat (and who, in groups).
      final title = widget.chatId != null || !group ? nameOf(m.senderUserId) : '${nameOf(m.senderUserId)} in ${where ?? 'a chat'}';
      return ContentWidth(
        child: ListTile(
          key: Key('search-hit-${m.id}'),
          leading: PersonAvatar(
            label: widget.chatId != null || !group ? nameOf(m.senderUserId) : (where ?? '?'),
            colorKey: widget.chatId != null || !group ? m.senderUserId : m.chatId,
            userId: widget.chatId != null || !group ? m.senderUserId : null,
            group: widget.chatId == null && group,
            radius: 20,
          ),
          title: Row(children: [
            Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: Space.sm),
            Text(
              shortTime(DateTime.fromMillisecondsSinceEpoch(m.createdAt), h24: MediaQuery.alwaysUse24HourFormatOf(context)),
              style: theme.textTheme.labelSmall?.copyWith(color: s.onSurfaceVariant),
            ),
          ]),
          subtitle: _Highlighted(snippetAround(h.text, _query), _query),
          onTap: () => context.go('/chats/${m.chatId}?m=${m.id}'),
        ),
      );
    }

    final Widget body;
    if (_query.isEmpty) {
      body = EmptyState(
        art: Icon(Icons.manage_search_rounded, size: 48, color: s.onSurfaceVariant),
        title: widget.chatId == null ? 'Search people and messages' : 'Search your messages',
        body: 'Messages are searched on this device. Only messages it has received are included.',
      );
    } else if (_hits.isEmpty && people.isEmpty) {
      body = EmptyState(
        art: Icon(Icons.search_off_rounded, size: 48, color: s.onSurfaceVariant),
        title: widget.chatId == null ? 'Nothing matches "$_query"' : 'No messages match "$_query"',
      );
    } else {
      // Section headings only when both kinds of result show.
      final sections = people.isNotEmpty && _hits.isNotEmpty;
      final rows = <Widget Function()>[
        if (sections) () => heading('People'),
        for (final u in people) () => person(u),
        if (sections) () => heading('Messages'),
        for (final h in _hits) () => hit(h),
      ];
      body = ListView.builder(
        padding: EdgeInsets.only(bottom: Space.xl + MediaQuery.paddingOf(context).bottom),
        itemCount: rows.length,
        itemBuilder: (context, i) => rows[i](),
      );
    }

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: _close),
          titleSpacing: 0,
          title: TextField(
            key: const Key('search-field'),
            controller: _field,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            style: theme.textTheme.titleMedium,
            decoration: InputDecoration(
              hintText: scopeTitle == null ? 'Search people and messages' : 'Search in $scopeTitle',
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
            ),
          ),
          actions: [
            if (_field.text.isNotEmpty)
              IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close_rounded),
                onPressed: () {
                  _field.clear();
                  setState(() {
                    _query = '';
                    _hits = const [];
                  });
                },
              ),
            const SizedBox(width: Space.xs),
          ],
        ),
        body: body,
      ),
    );
  }
}

/// [text] with each match of [query] in bold.
class _Highlighted extends StatelessWidget {
  const _Highlighted(this.text, this.query, {this.strongBase = false});

  final String text, query;

  /// Title style (a name) rather than the muted snippet style.
  final bool strongBase;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = strongBase
        ? theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurface)
        : theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final strong = base?.copyWith(color: theme.colorScheme.onSurface, fontWeight: FontWeight.w700);
    final spans = <TextSpan>[];
    var at = 0;
    for (final (start, end) in matchRanges(text, query)) {
      if (start > at) spans.add(TextSpan(text: text.substring(at, start)));
      spans.add(TextSpan(text: text.substring(start, end), style: strong));
      at = end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return Text.rich(TextSpan(children: spans, style: base), maxLines: 2, overflow: TextOverflow.ellipsis);
  }
}
