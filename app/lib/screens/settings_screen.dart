// You and your family: devices, the admin pages, developer tools and signing out, in one place.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../dev_tools.dart';
import '../session/session_controller.dart';
import '../theme/tokens.dart';
import '../widgets/brand_mark.dart';
import '../widgets/common.dart';
import '../widgets/person_avatar.dart';
import 'account_providers.dart';
import 'sign_out.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    ref.watch(meProvider); // keeps the name and admin flag current, as the home screen does
    final state = ref.watch(sessionProvider);
    final session = state is SignedIn ? state.session : null;
    final admin = session?.isAdmin ?? false;
    final name = session?.name ?? 'You';
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
                PersonAvatar(label: name, colorKey: session?.userId ?? '', radius: 32),
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
              row(Icons.devices_rounded, 'Devices', 'Your signed-in phones and computers', '/devices',
                  key: const Key('settings-devices')),
            ]),
            if (admin)
              SettingsGroup(title: 'Family', children: [
                row(Icons.diversity_3_rounded, 'Family members', 'Admins, account resets, recovery code', '/family',
                    key: const Key('settings-family')),
                row(Icons.person_add_alt_rounded, 'Invite someone', 'A one-time link to join', '/invite',
                    key: const Key('settings-invite')),
                row(Icons.photo_library_outlined, 'Media storage', 'Space used by photos and voice',
                    '/storage',
                    key: const Key('settings-storage')),
              ]),
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
          ]),
        ),
      ]),
    );
  }
}
