// Admin: the family. Reset someone who lost every device, make a second admin, save the admin
// recovery code, and the links to invites and media storage.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../admin/admin_providers.dart';
import '../api/models.dart';
import '../chat/wire.dart';
import '../session/session_controller.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import '../widgets/person_avatar.dart';
import 'account_providers.dart';
import 'sign_out.dart';

class FamilyScreen extends ConsumerWidget {
  const FamilyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final family = ref.watch(familyProvider);
    final me = ref.watch(meProvider).value;
    final session = ref.watch(sessionProvider);
    final myId = session is SignedIn ? session.session.userId : null;
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go('/settings')),
        title: const Text('Family'),
        actions: [
          IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh_rounded), onPressed: () => ref.invalidate(familyProvider)),
        ],
      ),
      body: switch (family) {
        AsyncData(value: final users) => ListView(
            padding: EdgeInsets.only(top: Space.sm, bottom: Space.xxl + MediaQuery.paddingOf(context).bottom),
            children: [
              ContentWidth(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (me != null && !me.recoveryCodeSet) const _RecoveryCodeCard(),
                  if (users.where((u) => u.isAdmin).length < 2) const _SecondAdminCard(),
                  SettingsGroup(
                    title: '${users.length} ${users.length == 1 ? 'person' : 'people'}',
                    children: [for (final u in users) _UserTile(user: u, mine: u.id == myId)],
                  ),
                  SettingsGroup(children: [
                    ListTile(
                      leading: const TileIcon(Icons.person_add_alt_rounded),
                      title: const Text('Invite someone'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => context.go('/invite'),
                    ),
                    ListTile(
                      leading: const TileIcon(Icons.photo_library_outlined),
                      title: const Text('Media storage'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => context.go('/storage'),
                    ),
                    if (me != null && me.recoveryCodeSet)
                      ListTile(
                        key: const Key('new-recovery-code'),
                        leading: const TileIcon(Icons.key_rounded),
                        title: const Text('Make a new admin recovery code'),
                        subtitle: const Text('The old code stops working.'),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => context.go('/family/recovery-code'),
                      ),
                  ]),
                ]),
              ),
            ],
          ),
        AsyncError() => EmptyState(
            art: Icon(Icons.cloud_off_rounded, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
            title: "Couldn't load the family.",
            body: 'Check your connection and try again.',
            action: OutlinedButton(onPressed: () => ref.invalidate(familyProvider), child: const Text('Retry')),
          ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _RecoveryCodeCard extends StatelessWidget {
  const _RecoveryCodeCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    return Card(
      key: const Key('recovery-code-card'),
      margin: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.lg),
      color: s.secondaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.lg)),
      child: Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: s.onSecondaryContainer),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.key_rounded, color: s.onSecondaryContainer),
            const SizedBox(width: Space.sm),
            Expanded(
              child: Text(
                'Save your admin recovery code',
                style: theme.textTheme.titleMedium?.copyWith(color: s.onSecondaryContainer),
              ),
            ),
          ]),
          const SizedBox(height: Space.sm),
          const Text(
            'If you lose every device and there is no other admin, this printed code is the only way '
            'back into your admin account.',
          ),
          const SizedBox(height: Space.lg),
          FilledButton(
            key: const Key('open-recovery-code'),
            style: FilledButton.styleFrom(backgroundColor: s.onSecondaryContainer, foregroundColor: s.secondaryContainer),
            onPressed: () => context.go('/family/recovery-code'),
            child: const Text('Save recovery code'),
          ),
          ]),
        ),
      ),
    );
  }
}

class _SecondAdminCard extends StatelessWidget {
  const _SecondAdminCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('second-admin-card'),
      margin: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.lg),
      child: Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Add a second admin', style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.sm),
          Text(
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            'If you lose every device, another admin can reset your account. Pick someone you trust '
            'below and choose "Make admin".',
          ),
        ]),
      ),
    );
  }
}

class _UserTile extends ConsumerWidget {
  const _UserTile({required this.user, required this.mine});

  final UserDto user;
  final bool mine;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = user.devices.where((d) => !d.revoked).length;
    final details = [
      if (mine) 'You',
      if (user.isAdmin) 'Admin',
      live == 0 ? 'No devices' : '$live ${live == 1 ? 'device' : 'devices'}',
    ];
    return ListTile(
      key: Key('family-user-${user.id}'),
      leading: PersonAvatar(label: user.name, colorKey: user.id),
      title: Text(user.name),
      subtitle: Text(details.join(', ')),
      trailing: mine
          ? null
          : PopupMenuButton<String>(
              key: Key('family-menu-${user.id}'),
              tooltip: 'Actions for ${user.name}',
              onSelected: (v) => v == 'reset' ? _reset(context, ref) : _makeAdmin(context, ref),
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'reset', child: Text('Reset account')),
                if (!user.isAdmin) const PopupMenuItem(value: 'admin', child: Text('Make admin')),
              ],
            ),
    );
  }

  Future<void> _reset(BuildContext context, WidgetRef ref) async {
    final name = user.name;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("Reset $name's account?"),
        content: Text(
          'Use this only if $name lost every device. All of their devices are signed out now, and you get '
          'a new one-time link for them. Their chat history comes back from the others in their chats, '
          'not from you. Everyone who chats with $name will see that you reset the account.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('confirm-reset'),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset account'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final admin = ref.read(adminServiceProvider);
    if (admin == null) return;
    try {
      final link = await admin.resetUser(user.id, currentIdentityPub: user.identityPub);
      ref.invalidate(familyProvider);
      if (context.mounted) await showDialog<void>(context: context, builder: (_) => _ResetLinkDialog(name: name, link: link));
    } catch (e) {
      ref.invalidate(familyProvider);
      if (context.mounted) {
        final msg = e is ApiException && e.code == 'conflict'
            ? "$name's account changed meanwhile. Check the list and try again."
            : apiErrorMessage(e);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    }
  }

  Future<void> _makeAdmin(BuildContext context, WidgetRef ref) async {
    final name = user.name;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Make $name an admin?'),
        content: Text('$name will be able to invite people, reset accounts (including yours) and make other admins.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(key: const Key('confirm-admin'), onPressed: () => Navigator.pop(context, true), child: const Text('Make admin')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(adminServiceProvider)?.makeAdmin(user.id);
      ref.invalidate(familyProvider);
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$name is now an admin')));
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(apiErrorMessage(e))));
    }
  }
}

class _ResetLinkDialog extends StatelessWidget {
  const _ResetLinkDialog({required this.name, required this.link});

  final String name;
  final ResetLink link;

  @override
  Widget build(BuildContext context) {
    final expires = MaterialLocalizations.of(context).formatMediumDate(link.expiresAt);
    return AlertDialog(
      title: Text("$name's new sign-in link"),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Card(child: Padding(padding: const EdgeInsets.all(Space.lg), child: SelectableText(link.url, key: const Key('reset-link')))),
        const SizedBox(height: 8),
        Text(
          'Give this to $name yourself (in person or on a call). It works once and expires on $expires. '
          'Their old devices are already signed out.',
        ),
      ]),
      actions: [
        TextButton(
          key: const Key('copy-reset-link'),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: link.url));
            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
          },
          child: const Text('Copy link'),
        ),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ],
    );
  }
}
