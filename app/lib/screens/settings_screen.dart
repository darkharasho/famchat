// You and your family: devices, the admin pages, developer tools, signing out and deleting your
// account, in one place.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../chat/chat_sync.dart';
import '../chat/providers.dart';
import '../dev_tools.dart';
import '../profile/profile_photo_tile.dart';
import '../push/notification_settings.dart';
import '../session/session_controller.dart';
import '../theme/tokens.dart';
import '../update/update_banner.dart';
import '../widgets/brand_mark.dart';
import '../widgets/common.dart';
import '../widgets/person_avatar.dart';
import 'account_providers.dart';
import 'delete_account.dart';
import 'sign_out.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    // The chats stay open under Settings, keeping their /me; opening Settings reads it again (an
    // admin who was just promoted sees the family pages).
    Future.microtask(() {
      if (mounted) ref.invalidate(meProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    ref.watch(meProvider); // keeps the name and admin flag current, as the home screen does
    final state = ref.watch(sessionProvider);
    final session = state is SignedIn ? state.session : null;
    final admin = session?.isAdmin ?? false;
    final myId = ref.watch(myUserIdProvider);
    // The directory has a rename at once; the session catches up at the next /me.
    final name = (myId == null ? null : ref.watch(usersProvider).value?[myId]?.name) ?? session?.name ?? 'You';
    Widget row(IconData icon, String title, String subtitle, String route, {Key? key}) => ListTile(
          key: key,
          leading: TileIcon(icon),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => context.go(route),
        );

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go('/')),
        title: const Text('Settings'),
      ),
      body: ListView(padding: EdgeInsets.only(bottom: Space.xxl + MediaQuery.paddingOf(context).bottom), children: [
        ContentWidth(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.xl, Space.md, Space.xl, Space.xl),
              child: Row(children: [
                PersonAvatar(
                  label: name,
                  colorKey: session?.userId ?? '',
                  userId: ref.watch(myUserIdProvider) ?? session?.userId,
                  radius: 32,
                ),
                const SizedBox(width: Space.lg),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(name, style: theme.textTheme.headlineSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(
                      [if (admin) 'Family admin' else 'Family member', if (session != null) 'on ${session.deviceName}']
                          .join(', '),
                      style: theme.textTheme.bodyMedium?.copyWith(color: s.onSurfaceVariant),
                    ),
                  ]),
                ),
              ]),
            ),
            SettingsGroup(title: 'You', children: [
              ListTile(
                key: const Key('settings-name'),
                leading: const TileIcon(Icons.badge_outlined),
                title: const Text('Your name'),
                subtitle: Text(name),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _rename(context, ref, name),
              ),
              const ProfilePhotoTile(),
              row(Icons.devices_rounded, 'Devices', 'Your signed-in phones and computers', '/settings/devices',
                  key: const Key('settings-devices')),
            ]),
            const NotificationSettingsGroup(),
            if (admin)
              SettingsGroup(title: 'Family', children: [
                row(Icons.diversity_3_rounded, 'Family members', 'Admins, account resets, recovery code', '/settings/family',
                    key: const Key('settings-family')),
                row(Icons.person_add_alt_rounded, 'Invite someone', 'A one-time link to join', '/settings/invite',
                    key: const Key('settings-invite')),
                row(Icons.photo_library_outlined, 'Media storage', 'Space used by photos and voice',
                    '/settings/storage',
                    key: const Key('settings-storage')),
              ]),
            const AppVersionGroup(),
            if (ref.watch(developerToolsProvider))
              SettingsGroup(title: 'Developer', children: [
                row(Icons.science_outlined, 'Platform spikes', 'Check crypto, storage, sockets and audio here',
                    '/spikes',
                    key: const Key('settings-spikes')),
              ]),
            SettingsGroup(children: [
              ListTile(
                key: const Key('settings-sign-out'),
                leading: TileIcon(Icons.logout_rounded, color: s.onErrorContainer, background: s.errorContainer),
                title: Text('Sign out', style: TextStyle(color: s.error)),
                subtitle: const Text("Deletes this device's keys"),
                onTap: () => confirmSignOut(context, ref),
              ),
            ]),
            SettingsGroup(children: [
              ListTile(
                key: const Key('settings-delete-account'),
                leading: TileIcon(Icons.delete_forever_rounded, color: s.onErrorContainer, background: s.errorContainer),
                title: Text('Delete my account', style: TextStyle(color: s.error)),
                subtitle: const Text('Your account, devices and the messages you sent. Permanent.'),
                onTap: () => confirmDeleteAccount(context, ref),
              ),
            ]),
            const SizedBox(height: Space.lg),
            const Center(child: Wordmark(size: 22)),
            const SizedBox(height: Space.sm),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.xl),
              child: Text(
                'Messages, photos and voice are end-to-end encrypted. Only your family can read them.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: Space.xs),
            Center(
              child: TextButton(
                onPressed: () => showLicensePage(context: context, applicationName: 'FamChat'),
                child: const Text('Open-source licenses'),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// Asks for a new name and saves it (everyone sees it as soon as their directory refreshes).
Future<void> _rename(BuildContext context, WidgetRef ref, String current) async {
  final picked = await showDialog<String>(context: context, builder: (context) => _RenameDialog(current: current));
  if (picked == null || picked == current || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await ref.read(chatSyncProvider)?.rename(picked);
    ref.invalidate(meProvider);
  } catch (_) {
    messenger.showSnackBar(const SnackBar(content: Text("Couldn't change your name.")));
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.current});
  final String current;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _text = TextEditingController(text: widget.current);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String get _value => _text.text.trim();

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Your name'),
        content: TextField(
          key: const Key('name-field'),
          controller: _text,
          autofocus: true,
          maxLength: ChatSync.maxNameLength,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(helperText: 'How your family sees you'),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) {
            if (_value.isNotEmpty) Navigator.pop(context, _value);
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: _value.isEmpty ? null : () => Navigator.pop(context, _value),
            child: const Text('Save'),
          ),
        ],
      );
}
