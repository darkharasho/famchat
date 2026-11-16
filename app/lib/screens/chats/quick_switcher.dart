// Ctrl/Cmd+K: jump to any chat by typing part of its name.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/db/chat_db.dart';
import '../../chat/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/person_avatar.dart';

/// [items] matching [query]: titles that start with it, then titles with a word that starts with
/// it, then titles containing it. Case-insensitive; order kept within each tier; empty query → all.
List<T> rankChats<T>(String query, List<T> items, String Function(T) title) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return items;
  int? tier(T item) {
    final t = title(item).toLowerCase();
    if (t.startsWith(q)) return 0;
    if (t.split(RegExp(r'\s+')).any((w) => w.startsWith(q))) return 1;
    if (t.contains(q)) return 2;
    return null;
  }

  final scored = [
    for (final (i, item) in items.indexed)
      if (tier(item) case final t?) (t, i, item),
  ]..sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
  return [for (final s in scored) s.$3];
}

Future<void> showQuickSwitcher(BuildContext context) => showDialog<void>(
      context: context,
      barrierLabel: 'Close',
      builder: (_) => const _QuickSwitcher(),
    );

class _QuickSwitcher extends ConsumerStatefulWidget {
  const _QuickSwitcher();

  @override
  ConsumerState<_QuickSwitcher> createState() => _QuickSwitcherState();
}

class _QuickSwitcherState extends ConsumerState<_QuickSwitcher> {
  final _query = TextEditingController();
  int _selected = 0;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  bool _done = false;

  void _open(ChatListItem item) {
    // Enter can arrive twice (as a key and as the field's submit), and a second pop would close the page.
    if (_done) return;
    _done = true;
    Navigator.of(context).pop();
    GoRouter.of(context).go('/chats/${item.chat.id}');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final users = ref.watch(usersProvider).value ?? const {};
    final me = ref.watch(myUserIdProvider);
    final all = ref.watch(chatListProvider).value ?? const <ChatListItem>[];
    String title(ChatListItem i) => chatTitle(i.chat, i.members, users, me);
    final matches = rankChats(_query.text, all, title).take(8).toList();
    final selected = matches.isEmpty ? -1 : _selected.clamp(0, matches.length - 1);

    void move(int by) {
      if (matches.isEmpty) return;
      setState(() => _selected = (selected + by) % matches.length);
    }

    return Dialog(
      key: const Key('quick-switcher'),
      alignment: const Alignment(0, -0.6),
      insetPadding: const EdgeInsets.all(Space.xl),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 480),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, Space.lg, Space.lg, Space.sm),
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.arrowDown): () => move(1),
                const SingleActivator(LogicalKeyboardKey.arrowUp): () => move(-1),
                const SingleActivator(LogicalKeyboardKey.enter): () {
                  if (selected >= 0) _open(matches[selected]);
                },
              },
              child: TextField(
                key: const Key('quick-switcher-field'),
                controller: _query,
                autofocus: true,
                textInputAction: TextInputAction.go,
                decoration: const InputDecoration(
                  hintText: 'Find a chat',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
                onChanged: (_) => setState(() => _selected = 0),
                onSubmitted: (_) {
                  if (selected >= 0) {
                    _open(matches[selected]);
                  }
                },
              ),
            ),
          ),
          if (matches.isEmpty)
            Padding(
              padding: const EdgeInsets.all(Space.xl),
              child: Text(
                'No chat matches',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            )
          else
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(Space.sm, 0, Space.sm, Space.sm),
                children: [
                  for (final (i, item) in matches.indexed)
                    ListTile(
                      selected: i == selected,
                      leading: PersonAvatar(
                        label: title(item),
                        colorKey: item.chat.kind == 'group'
                            ? item.chat.id
                            : (otherMember(item.chat, item.members, me) ?? item.chat.id),
                        group: item.chat.kind == 'group',
                        radius: 18,
                      ),
                      title: Text(title(item), maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => _open(item),
                    ),
                ],
              ),
            ),
        ]),
      ),
    );
  }
}
