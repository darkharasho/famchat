import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/models.dart' show Family;
import '../../chat/chat_sync.dart' show ChatSync;
import '../../chat/db/chat_db.dart';
import '../../chat/providers.dart';
import '../../media/photo.dart';
import '../../media/photo_picker.dart';
import '../../media/providers.dart';
import '../../profile/avatar.dart';
import '../sign_out.dart' show apiErrorMessage;
import '../../settings/time_format.dart' show clockTime, lastSeenLabel;
import '../../theme/tokens.dart';
import '../../widgets/common.dart';
import '../../widgets/person_avatar.dart';

/// "Until I turn it back on": the server's latest accepted mute time (year 9999).
const muteForever = 253402300799000;

/// How long notifications from a chat stay off.
String muteLabel(int? until, DateTime now, {required bool h24}) {
  if (until == null || until <= now.millisecondsSinceEpoch) return 'Off';
  if (until >= muteForever) return 'Until you turn them back on';
  final t = DateTime.fromMillisecondsSinceEpoch(until);
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  if (day == today) return 'Until ${clockTime(t, h24: h24)}';
  if (day == DateTime(today.year, today.month, today.day + 1)) return 'Until tomorrow, ${clockTime(t, h24: h24)}';
  return 'Until ${t.month}/${t.day}';
}

/// Members, add people, notifications, leave, and (for the creator) remove.
class GroupInfoScreen extends ConsumerStatefulWidget {
  const GroupInfoScreen({super.key, required this.chatId});

  final String chatId;

  @override
  ConsumerState<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends ConsumerState<GroupInfoScreen> {
  bool _busy = false;

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
          ],
        ),
      ) ==
      true;

  void _goHome() => context.go('/');

  /// Muted: unmute. Otherwise asks for how long, then mutes.
  Future<void> _mute(ChatRow chat) async {
    final sync = ref.read(chatSyncProvider);
    if (sync == null) return;
    final muted = (chat.mutedUntil ?? 0) > DateTime.now().millisecondsSinceEpoch;
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (muted)
            ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: const Text('Unmute'),
              onTap: () => Navigator.pop(context, 0),
            )
          else ...[
            for (final (label, d) in const [
              ('For 1 hour', Duration(hours: 1)),
              ('For 8 hours', Duration(hours: 8)),
              ('For 1 week', Duration(days: 7)),
            ])
              ListTile(
                leading: const Icon(Icons.schedule_rounded),
                title: Text(label),
                onTap: () => Navigator.pop(context, DateTime.now().add(d).millisecondsSinceEpoch),
              ),
            ListTile(
              leading: const Icon(Icons.notifications_off_outlined),
              title: const Text('Until I turn it back on'),
              onTap: () => Navigator.pop(context, muteForever),
            ),
          ],
        ]),
      ),
    );
    if (picked == null) return;
    await _run(() => sync.mute(chat.id, picked == 0 ? null : picked));
  }

  void _snack(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Asks for a new group name, then renames.
  Future<void> _rename(ChatRow chat) async {
    final sync = ref.read(chatSyncProvider);
    if (sync == null) return;
    final title = await showDialog<String>(context: context, builder: (context) => _RenameGroupDialog(title: chat.title ?? ''));
    final t = title?.trim();
    if (t == null || t.isEmpty || t == chat.title) return;
    await _run(() => sync.renameChat(chat.id, t));
  }

  /// Choose, take or remove the group's photo.
  Future<void> _photo(ChatRow chat) async {
    final sync = ref.read(chatSyncProvider);
    if (sync == null) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose a photo'),
            onTap: () => Navigator.pop(context, 'choose'),
          ),
          if (cameraAvailable)
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(context, 'take'),
            ),
          if (chat.avatarKey != null)
            ListTile(
              leading: Icon(Icons.delete_outline_rounded, color: Theme.of(context).colorScheme.error),
              title: Text('Remove photo', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () => Navigator.pop(context, 'remove'),
            ),
        ]),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'remove') {
      await _run(() => sync.setChatAvatar(chat.id, null));
      return;
    }
    await _run(() async {
      final picked = await ref.read(photoPickerProvider)(action == 'take' ? PickSource.camera : PickSource.library);
      final original = picked.whereType<PickedPhoto>().firstOrNull;
      if (original == null) {
        if (picked.isNotEmpty) _snack('Pick a photo, not a video.');
        return;
      }
      final Uint8List jpeg;
      try {
        jpeg = await avatarJpeg(ref.read(photoProcessorProvider), original.bytes, offload: ref.read(mediaOffloadProvider));
      } on UnsupportedImageException {
        _snack("That image can't be used.");
        return;
      }
      final key = await sync.setChatAvatar(chat.id, jpeg);
      // Shown from the cache at once, never downloaded back.
      if (key != null) await ref.read(mediaDbProvider).cachePut(chatAvatarCacheKey(chat.id, key), jpeg, maxBytes: mediaCacheBytes);
    });
  }

  /// Runs [f]; shows the error and returns false if it throws.
  Future<bool> _run(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
      return true;
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(apiErrorMessage(e))));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// "Created the group" and/or when they were last seen.
  Widget? _memberSubtitle(bool created, int? lastSeenAt) {
    final seen = lastSeenAt == null
        ? null
        : lastSeenLabel(DateTime.fromMillisecondsSinceEpoch(lastSeenAt), h24: MediaQuery.alwaysUse24HourFormatOf(context));
    final parts = [if (created) 'Created the group', ?seen];
    return parts.isEmpty ? null : Text(parts.join(' · '));
  }

  @override
  Widget build(BuildContext context) {
    final chatId = widget.chatId;
    final chat = ref.watch(chatProvider(chatId)).value;
    final members = ref.watch(membersProvider(chatId)).value ?? const <MemberRow>[];
    final users = ref.watch(usersProvider).value ?? const <String, UserRow>{};
    final online = ref.watch(onlineProvider).value ?? const <String>{};
    final me = ref.watch(myUserIdProvider);
    final sync = ref.watch(chatSyncProvider);
    final theme = Theme.of(context);
    if (chat == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('This chat is no longer available.')));
    }
    final group = chat.kind == 'group';
    final creator = chat.createdBy == me;
    final title = chatTitle(chat, members, users, me);
    final sorted = [...members]..sort((a, b) => (users[a.userId]?.name ?? '').compareTo(users[b.userId]?.name ?? ''));
    final s = theme.colorScheme;
    // Only people in two or more families get told which one a group belongs to.
    final families = ref.watch(myFamiliesProvider).value ?? const <Family>[];
    final familyName = group && families.length > 1
        ? families.where((f) => f.id == chat.familyId).map((f) => f.name).firstOrNull
        : null;
    return Scaffold(
      appBar: AppBar(
        title: Text(group ? 'Group info' : 'Chat info'),
        leading: BackButton(onPressed: () => context.go('/chats/$chatId')),
      ),
      body: ListView(padding: EdgeInsets.only(bottom: Space.xxl + MediaQuery.paddingOf(context).bottom), children: [
        ContentWidth(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: Space.lg),
            Center(
              child: Stack(clipBehavior: Clip.none, children: [
                Material(
                  type: MaterialType.transparency,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    key: const Key('group-photo'),
                    onTap: group && !_busy && sync != null ? () => _photo(chat) : null,
                    child: PersonAvatar(
                      label: title,
                      colorKey: group ? chat.id : (otherMember(chat, members, me) ?? chat.id),
                      userId: group ? null : otherMember(chat, members, me),
                      group: group,
                      chatId: chat.id,
                      chatPhotoKey: chat.avatarKey,
                      radius: 44,
                    ),
                  ),
                ),
                if (group)
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: IgnorePointer(
                      child: CircleAvatar(
                        radius: 15,
                        backgroundColor: s.primary,
                        child: Icon(Icons.photo_camera_outlined, size: 16, color: s.onPrimary, semanticLabel: 'Change group photo'),
                      ),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: Space.md),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.xl),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (group) const SizedBox(width: 40),
                Flexible(child: Text(title, textAlign: TextAlign.center, style: theme.textTheme.headlineSmall)),
                if (group)
                  IconButton(
                    key: const Key('rename-group'),
                    tooltip: 'Rename group',
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    onPressed: _busy || sync == null ? null : () => _rename(chat),
                  ),
              ]),
            ),
            if (familyName != null)
              Padding(
                padding: const EdgeInsets.only(top: Space.xs, left: Space.xl, right: Space.xl),
                child: Text('Family: $familyName',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(color: s.onSurfaceVariant)),
              ),
            const SizedBox(height: Space.xl),
            SettingsGroup(children: [
              ListTile(
                leading: const TileIcon(Icons.person_add_alt_rounded),
                title: const Text('Add people'),
                subtitle: group ? null : const Text('Starts a new group; this chat stays between you two'),
                enabled: !_busy,
                onTap: () => group
                    ? context.go('/chats/$chatId/info/add')
                    : context.go('/new?with=${otherMember(chat, members, me) ?? ''}'),
              ),
            ]),
            SettingsGroup(children: [
              ListTile(
                key: const Key('mute-chat'),
                leading: TileIcon(
                  (chat.mutedUntil ?? 0) > DateTime.now().millisecondsSinceEpoch
                      ? Icons.notifications_off_outlined
                      : Icons.notifications_none_rounded,
                ),
                title: const Text('Mute notifications'),
                subtitle: Text(muteLabel(chat.mutedUntil, DateTime.now(), h24: MediaQuery.alwaysUse24HourFormatOf(context))),
                enabled: !_busy && sync != null,
                onTap: () => _mute(chat),
              ),
            ]),
            SettingsGroup(title: membersLabel(members.length), children: [
              for (final m in sorted)
                ListTile(
                  leading: PersonAvatar(
                    label: users[m.userId]?.name ?? '?',
                    colorKey: m.userId,
                    userId: m.userId,
                    online: online.contains(m.userId),
                    ringColor: theme.cardTheme.color,
                  ),
                  title: Text(m.userId == me ? '${users[m.userId]?.name ?? 'You'} (you)' : users[m.userId]?.name ?? 'Unknown'),
                  subtitle: _memberSubtitle(m.userId == chat.createdBy, m.userId != me && !online.contains(m.userId)
                      ? users[m.userId]?.lastSeenAt
                      : null),
                  trailing: group && creator && m.userId != me
                      ? IconButton(
                          tooltip: 'Remove ${users[m.userId]?.name ?? ''}',
                          icon: const Icon(Icons.person_remove_outlined),
                          onPressed: _busy || sync == null
                              ? null
                              : () async {
                                  final name = users[m.userId]?.name ?? 'them';
                                  if (!await _confirm('Remove $name?',
                                      "$name won't see new messages. The group gets a new key.", 'Remove')) {
                                    return;
                                  }
                                  await _run(() => sync.removeMember(chatId, m.userId));
                                },
                        )
                      : null,
                ),
            ]),
            if (group)
              SettingsGroup(children: [
                ListTile(
                  leading: TileIcon(Icons.logout_rounded, color: s.onErrorContainer, background: s.errorContainer),
                  title: Text('Leave group', style: TextStyle(color: s.error)),
                  enabled: !_busy && sync != null,
                  onTap: () async {
                    if (!await _confirm('Leave $title?', "You won't get new messages from this group.", 'Leave')) return;
                    if (await _run(() => sync!.leave(chatId)) && mounted) _goHome();
                  },
                ),
              ]),
          ]),
        ),
      ]),
    );
  }
}

class _RenameGroupDialog extends StatefulWidget {
  const _RenameGroupDialog({required this.title});
  final String title;

  @override
  State<_RenameGroupDialog> createState() => _RenameGroupDialogState();
}

class _RenameGroupDialogState extends State<_RenameGroupDialog> {
  late final _text = TextEditingController(text: widget.title);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String get _value => _text.text.trim();

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Group name'),
        content: TextField(
          key: const Key('rename-group-field'),
          controller: _text,
          autofocus: true,
          maxLength: ChatSync.maxTitleLength,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) {
            if (_value.isNotEmpty) Navigator.pop(context, _value);
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: _value.isEmpty ? null : () => Navigator.pop(context, _value), child: const Text('Save')),
        ],
      );
}
