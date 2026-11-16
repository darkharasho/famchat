import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/providers.dart';
import '../sign_out.dart' show apiErrorMessage;

/// Pick one person for a 1:1, or several (plus a title) for a group.
class NewChatScreen extends ConsumerStatefulWidget {
  const NewChatScreen({super.key, this.preselected = const [], this.addTo});

  final List<String> preselected;

  /// Add the picked people to this group instead of starting a chat.
  final String? addTo;

  @override
  ConsumerState<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends ConsumerState<NewChatScreen> {
  late final Set<String> _picked = {...widget.preselected};
  final _title = TextEditingController();
  bool _titleEdited = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final sync = ref.read(chatSyncProvider);
    if (sync != null) unawaited(sync.directory.refresh().then((_) {}, onError: (Object _) {}));
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _toggle(String id, Map<String, String> names) {
    setState(() {
      _picked.contains(id) ? _picked.remove(id) : _picked.add(id);
      if (!_titleEdited) _title.text = [for (final p in _picked) names[p] ?? '?'].join(', ');
    });
  }

  Future<void> _create() async {
    final sync = ref.read(chatSyncProvider);
    if (sync == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final people = _picked.toList();
      final addTo = widget.addTo;
      if (addTo != null) {
        await sync.addMembers(addTo, people);
        if (mounted) context.go('/chats/$addTo/info');
        return;
      }
      final id = people.length == 1
          ? await sync.openDirect(people.single)
          : await sync.createGroup(_title.text.trim().isEmpty ? 'Group' : _title.text.trim(), people);
      if (mounted) context.go('/chats/$id');
    } catch (e) {
      if (mounted) setState(() => _error = apiErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(myUserIdProvider);
    final addTo = widget.addTo;
    final existing = addTo == null
        ? const <String>{}
        : {for (final m in ref.watch(membersProvider(addTo)).value ?? const []) m.userId};
    final users = (ref.watch(usersProvider).value ?? const {})
        .values
        .where((u) => u.id != me && !existing.contains(u.id))
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final names = {for (final u in users) u.id: u.name};
    final group = addTo == null && _picked.length > 1;
    return Scaffold(
      appBar: AppBar(
        title: Text(addTo == null ? 'New chat' : 'Add people'),
        leading: BackButton(
          onPressed: () => context.canPop() ? context.pop() : context.go(addTo == null ? '/' : '/chats/$addTo/info'),
        ),
      ),
      body: Column(children: [
        if (group)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              key: const Key('group-title'),
              controller: _title,
              maxLength: 60,
              decoration: const InputDecoration(labelText: 'Group name'),
              onChanged: (_) => _titleEdited = true,
            ),
          ),
        Expanded(
          child: users.isEmpty
              ? const Center(child: Text('No one else here yet'))
              : ListView(children: [
                  for (final u in users)
                    CheckboxListTile(
                      value: _picked.contains(u.id),
                      onChanged: _busy ? null : (_) => _toggle(u.id, names),
                      title: Text(u.name),
                      secondary: CircleAvatar(child: Text(u.name.characters.first.toUpperCase())),
                    ),
                ]),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _picked.isEmpty || _busy ? null : _create,
              child: _busy
                  ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(addTo != null ? 'Add' : (group ? 'Create group' : 'Chat')),
            ),
          ),
        ),
      ]),
    );
  }
}
