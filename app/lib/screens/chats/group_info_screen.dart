import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/models.dart' show Family;
import '../../chat/db/chat_db.dart';
import '../../chat/providers.dart';
import '../sign_out.dart' show apiErrorMessage;
import '../../settings/time_format.dart' show clockTime;
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
              child: PersonAvatar(
                label: title,
                colorKey: group ? chat.id : (otherMember(chat, members, me) ?? chat.id),
                userId: group ? null : otherMember(chat, members, me),
                group: group,
                radius: 44,
              ),
            ),
            const SizedBox(height: Space.md),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.xl),
              child: Text(title, textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
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
                  subtitle: m.userId == chat.createdBy ? const Text('Created the group') : null,
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
