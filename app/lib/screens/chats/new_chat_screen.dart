import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/models.dart' show Family;
import '../../chat/db/chat_db.dart' show UserRow;
import '../../chat/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/common.dart';
import '../../widgets/person_avatar.dart';
import '../sign_out.dart' show apiErrorMessage;

/// The ids of the families [u] is in (`LocalUsers.familyIds`, JSON); empty if unreadable.
List<int> familyIdsOf(UserRow u) {
  try {
    return [for (final v in jsonDecode(u.familyIds) as List) if (v is int) v];
  } catch (_) {
    return const [];
  }
}

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

  /// With two or more families: the person chose "New group" (or came to add to a chat), and
  /// [_family] is the family they picked for it.
  bool _groupMode = false;
  int? _family;
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
      // A second person makes it a group, and with two or more families a group needs one chosen.
      if (_picked.length > 1 && widget.addTo == null && (ref.read(myFamiliesProvider).value?.length ?? 0) > 1) {
        _groupMode = true;
      }
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
      final families = ref.read(myFamiliesProvider).value ?? const <Family>[];
      final groupFamily = _family ?? (families.length == 1 ? families.single.id : null);
      final inGroupFlow = _groupMode || widget.preselected.isNotEmpty && families.length > 1;
      final id = people.length == 1 && !inGroupFlow
          ? await sync.openDirect(people.single)
          : await sync.createGroup(_title.text.trim().isEmpty ? 'Group' : _title.text.trim(), people, familyId: groupFamily);
      if (mounted) context.go('/chats/$id');
    } catch (e) {
      if (mounted) setState(() => _error = apiErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _noteToSelf() async {
    final sync = ref.read(chatSyncProvider);
    if (sync == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await sync.createGroup('Note to self', const []);
      if (mounted) context.go('/chats/$id');
    } catch (e) {
      if (mounted) setState(() => _error = apiErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The names of the [families] I share with [u], or null if none.
  Widget? _sharedFamilies(List<Family> families, UserRow u) {
    final ids = familyIdsOf(u);
    final names = [for (final f in families) if (ids.contains(f.id)) f.name];
    return names.isEmpty ? null : Text(names.join(', '), maxLines: 1, overflow: TextOverflow.ellipsis);
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(myUserIdProvider);
    final addTo = widget.addTo;
    final families = ref.watch(myFamiliesProvider).value ?? const <Family>[];
    final multi = families.length > 1;
    final groupFlow = addTo == null && multi && (_groupMode || widget.preselected.isNotEmpty);
    // The family step: a new group with two or more families starts by choosing one.
    final needFamily = groupFlow && _family == null;
    // The family whose people can be picked: the chat's (adding), or the one chosen (new group).
    final pickFrom = addTo != null ? ref.watch(chatProvider(addTo)).value?.familyId : (groupFlow ? _family : null);
    final existing = addTo == null
        ? const <String>{}
        : {for (final m in ref.watch(membersProvider(addTo)).value ?? const []) m.userId};
    final users = (ref.watch(usersProvider).value ?? const {})
        .values
        .where((u) => u.id != me && !existing.contains(u.id) && u.deleted != true && u.former != true)
        .where((u) => !multi || pickFrom == null || familyIdsOf(u).contains(pickFrom))
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final names = {for (final u in users) u.id: u.name};
    final group = addTo == null && (_picked.length > 1 || (groupFlow && _picked.isNotEmpty));
    return Scaffold(
      appBar: AppBar(
        title: Text(addTo == null ? (groupFlow ? 'New group' : 'New chat') : 'Add people'),
        leading: BackButton(
          onPressed: () => context.canPop() ? context.pop() : context.go(addTo == null ? '/' : '/chats/$addTo/info'),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ContentWidth(
          child: Column(children: [
            if (group && !needFamily)
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, 0),
                child: TextField(
                  key: const Key('group-title'),
                  controller: _title,
                  maxLength: 60,
                  decoration: const InputDecoration(labelText: 'Group name'),
                  onChanged: (_) => _titleEdited = true,
                ),
              ),
            Expanded(
              child: needFamily
                  ? ListView(padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs), children: [
                      for (final f in families)
                        ListTile(
                          key: Key('family-${f.id}'),
                          leading: const TileIcon(Icons.diversity_3_rounded),
                          title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () => setState(() {
                            _family = f.id;
                            // Drop anyone who isn't in the family chosen.
                            final inFamily = {
                              for (final u in (ref.read(usersProvider).value ?? const {}).values)
                                if (familyIdsOf(u).contains(f.id)) u.id,
                            };
                            _picked.removeWhere((p) => !inFamily.contains(p));
                          }),
                        ),
                    ])
                  : users.isEmpty
                  ? EmptyState(
                      art: Icon(Icons.diversity_3_rounded, size: 56, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      title: 'No one else here yet',
                      body: 'Once someone in the family joins, you can chat with them here. '
                          'Until then, try FamChat in a chat with just you.',
                      // A chat with only yourself: how a lone reviewer (docs/protocol.md
                      // "Reviewer accounts") tries text, photos and voice messages.
                      action: addTo == null
                          ? FilledButton.tonalIcon(
                              key: const Key('note-to-self'),
                              onPressed: _busy ? null : _noteToSelf,
                              icon: const Icon(Icons.edit_note_rounded),
                              label: const Text('Note to self'),
                            )
                          : null,
                    )
                  : ListView(padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs), children: [
                      if (addTo == null && multi && !groupFlow)
                        ListTile(
                          key: const Key('new-group'),
                          leading: const TileIcon(Icons.group_add_rounded),
                          title: const Text('New group'),
                          onTap: _busy ? null : () => setState(() => _groupMode = true),
                        ),
                      for (final u in users)
                        CheckboxListTile(
                          value: _picked.contains(u.id),
                          onChanged: _busy ? null : (_) => _toggle(u.id, names),
                          title: Text(u.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          // Only people in two or more families get a label (single-family users see none).
                          subtitle: multi && !groupFlow && addTo == null ? _sharedFamilies(families, u) : null,
                          secondary: PersonAvatar(label: u.name, colorKey: u.id, userId: u.id),
                        ),
                    ]),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.sm),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.lg),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _picked.isEmpty || _busy || needFamily ? null : _create,
                  child: _busy
                      ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(addTo != null ? 'Add' : (group ? 'Create group' : 'Chat')),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
