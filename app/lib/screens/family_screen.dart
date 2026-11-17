// One family: its people and their roles. Admins of an approved family invite people, reset someone
// who lost every device, make admins and remove members; its owner also demotes admins. Anyone can
// leave. A pending or declined family only shows its status, with rename and leave.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../admin/admin_providers.dart';
import '../api/models.dart';
import '../chat/providers.dart';
import '../chat/wire.dart';
import '../session/session_controller.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import '../widgets/person_avatar.dart';
import 'account_providers.dart';
import 'sign_out.dart';

class FamilyScreen extends ConsumerWidget {
  const FamilyScreen({super.key, required this.familyId});

  final int familyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final families = ref.watch(familiesProvider);
    final family = families.value?.where((f) => f.id == familyId).firstOrNull;
    final back = BackButton(onPressed: () => context.go('/settings/families'));
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    if (family == null) {
      return Scaffold(
        appBar: AppBar(leading: back, title: const Text('Family')),
        body: families.hasValue
            ? EmptyState(
                art: Icon(Icons.diversity_3_rounded, size: 48, color: muted),
                title: 'Family not found',
                body: "You aren't in this family.",
              )
            : families.hasError
                ? EmptyState(
                    art: Icon(Icons.cloud_off_rounded, size: 48, color: muted),
                    title: "Couldn't load the family.",
                    body: 'Check your connection and try again.',
                    action: OutlinedButton(onPressed: () => ref.invalidate(familiesProvider), child: const Text('Retry')),
                  )
                : const Center(child: CircularProgressIndicator()),
      );
    }
    final approved = family.status == 'approved';
    return Scaffold(
      appBar: AppBar(
        leading: back,
        title: Text(family.name),
        actions: [
          if (approved)
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () => ref
                ..invalidate(familyProvider)
                ..invalidate(reviewersProvider)
                ..invalidate(familiesProvider),
            ),
          // An approved family's admins; the creator of their own pending or declined family.
          if (approved ? family.admin : family.owner)
            IconButton(
              tooltip: 'Rename',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _rename(context, ref, family),
            ),
          PopupMenuButton<String>(
            key: const Key('family-overflow'),
            onSelected: (_) => _leave(context, ref, family),
            itemBuilder: (context) => [PopupMenuItem(value: 'leave', child: Text('Leave ${family.name}'))],
          ),
        ],
      ),
      body: approved
          ? _Members(family: family)
          : EmptyState(
              art: Icon(family.status == 'pending' ? Icons.hourglass_top_rounded : Icons.block_rounded, size: 48, color: muted),
              title: family.status == 'pending' ? 'Waiting for approval' : 'Declined',
              body: family.status == 'pending'
                  ? 'The operator approves new families. You can invite people once it is approved.'
                  : 'The operator declined this family. Leave it to dismiss the request.',
            ),
    );
  }
}

Future<void> _rename(BuildContext context, WidgetRef ref, Family family) async {
  final name = await showDialog<String>(context: context, builder: (context) => _RenameDialog(name: family.name));
  if (name == null || name == family.name || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await ref.read(apiClientProvider).renameFamily(family.id, name);
    await ref.read(familiesProvider.notifier).refresh();
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(apiErrorMessage(e))));
  }
}

Future<void> _leave(BuildContext context, WidgetRef ref, Family family) async {
  final me = ref.read(myUserIdProvider);
  if (me == null) return;
  final name = family.name;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Leave $name?'),
      content: Text(
        family.status == 'approved'
            ? "You leave $name's group chats. To come back, someone in $name has to invite you again."
            : 'Your request to start $name is withdrawn.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          key: const Key('confirm-leave'),
          style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Leave'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  final router = GoRouter.of(context);
  try {
    await ref.read(apiClientProvider).leaveOrRemove(family.id, me);
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(
      content: Text(e.code == 'last_admin' ? "You're the last admin. Make someone else an admin first." : apiErrorMessage(e)),
    ));
    return;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(apiErrorMessage(e))));
    return;
  }
  router.go('/settings/families');
  ref
    ..invalidate(familyProvider)
    ..invalidate(meProvider); // leaving family 1 ends its admin role on the account
  ref.read(familiesProvider.notifier).refresh().ignore();
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.name});
  final String name;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  static const maxLength = 40;
  late final _text = TextEditingController(text: widget.name);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String get _value => _text.text.trim();

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Rename family'),
        content: TextField(
          key: const Key('family-rename-field'),
          controller: _text,
          autofocus: true,
          maxLength: maxLength,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Family name'),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) {
            if (_value.isNotEmpty) Navigator.pop(context, _value);
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            key: const Key('family-rename-save'),
            onPressed: _value.isEmpty ? null : () => Navigator.pop(context, _value),
            child: const Text('Rename'),
          ),
        ],
      );
}

/// An approved family's people, and its admin sections for its admins.
class _Members extends ConsumerWidget {
  const _Members({required this.family});
  final Family family;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(familyProvider);
    final me = ref.watch(meProvider).value;
    final session = ref.watch(sessionProvider);
    final myId = session is SignedIn ? session.session.userId : null;
    final id = family.id;
    if (!users.hasValue) {
      return users.hasError
          ? EmptyState(
              art: Icon(Icons.cloud_off_rounded, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
              title: "Couldn't load the family.",
              body: 'Check your connection and try again.',
              action: OutlinedButton(onPressed: () => ref.invalidate(familyProvider), child: const Text('Retry')),
            )
          : const Center(child: CircularProgressIndicator());
    }
    // Deleted accounts stay in the directory but are no longer family; others' families aren't mine.
    final people = [
      for (final u in users.value!)
        if (!u.deleted && !u.former && (u.id == myId || u.families.any((f) => f.id == id))) u,
    ];
    bool adminHere(UserDto u) => u.id == myId ? family.admin : u.families.any((f) => f.id == id && f.admin);
    final admin = family.admin;
    return ListView(
      padding: EdgeInsets.only(top: Space.sm, bottom: Space.xxl + MediaQuery.paddingOf(context).bottom),
      children: [
        ContentWidth(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (admin && me != null && !me.recoveryCodeSet) _RecoveryCodeCard(familyId: id),
            if (admin && people.where(adminHere).length < 2) const _SecondAdminCard(),
            SettingsGroup(
              title: '${people.length} ${people.length == 1 ? 'person' : 'people'}',
              children: [
                for (final u in people)
                  _UserTile(user: u, family: family, mine: u.id == myId, admin: adminHere(u)),
              ],
            ),
            if (admin)
              SettingsGroup(children: [
                ListTile(
                  leading: const TileIcon(Icons.person_add_alt_rounded),
                  title: const Text('Invite someone'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => context.go('/settings/families/$id/invite'),
                ),
                // Media storage is the whole server's, so it stays with family 1's admins.
                if (id == 1)
                  ListTile(
                    leading: const TileIcon(Icons.photo_library_outlined),
                    title: const Text('Media storage'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => context.go('/settings/storage'),
                  ),
                if (me != null && me.recoveryCodeSet)
                  ListTile(
                    key: const Key('new-recovery-code'),
                    leading: const TileIcon(Icons.key_rounded),
                    title: const Text('Make a new admin recovery code'),
                    subtitle: const Text('The old code stops working.'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => context.go('/settings/families/$id/recovery-code'),
                  ),
              ]),
            // Until the operator has a screen of their own.
            if (id == 1 && me?.operator == true) const _ReviewerSection(),
          ]),
        ),
      ],
    );
  }
}

class _RecoveryCodeCard extends StatelessWidget {
  const _RecoveryCodeCard({required this.familyId});
  final int familyId;

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
            onPressed: () => context.go('/settings/families/$familyId/recovery-code'),
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
  const _UserTile({required this.user, required this.family, required this.mine, required this.admin});

  final UserDto user;
  final Family family;
  final bool mine;

  /// [user] is an admin of [family].
  final bool admin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = user.devices.where((d) => !d.revoked).length;
    final details = [
      if (mine) 'You',
      // Only my own ownership is known: the server tells each member only about themselves.
      if (mine && family.owner) 'Owner' else if (admin) 'Admin',
      live == 0 ? 'No devices' : '$live ${live == 1 ? 'device' : 'devices'}',
    ];
    // _Members only shows approved families, where admin power counts.
    final iAmAdmin = family.admin;
    final items = [
      if (iAmAdmin) const PopupMenuItem(value: 'reset', child: Text('Reset account')),
      if (iAmAdmin && !admin) const PopupMenuItem(value: 'admin', child: Text('Make admin')),
      if (iAmAdmin && !admin) PopupMenuItem(value: 'remove', child: Text('Remove from ${family.name}')),
      if (iAmAdmin && family.owner && admin) const PopupMenuItem(value: 'demote', child: Text('Remove admin')),
      if (ref.watch(meProvider).value?.operator == true)
        const PopupMenuItem(value: 'delete', child: Text('Delete account')),
    ];
    return ListTile(
      key: Key('family-user-${user.id}'),
      leading: PersonAvatar(label: user.name, colorKey: user.id, userId: user.id),
      title: Text(user.name),
      subtitle: Text(details.join(', ')),
      trailing: mine || items.isEmpty
          ? null
          : PopupMenuButton<String>(
              key: Key('family-menu-${user.id}'),
              tooltip: 'Actions for ${user.name}',
              onSelected: (v) => switch (v) {
                'reset' => _reset(context, ref),
                'admin' => _makeAdmin(context, ref),
                'remove' => _remove(context, ref),
                'demote' => _demote(context, ref),
                _ => _delete(context, ref),
              },
              itemBuilder: (context) => items,
            ),
    );
  }

  Future<bool> _confirm(BuildContext context, {required String title, required String body, required Key key, required String action, bool danger = true}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            key: key,
            style: danger ? FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error) : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true && context.mounted;
  }

  /// Runs [act], then refreshes the people (and [families], when counts or roles changed) and says
  /// [done], or the error.
  Future<void> _run(BuildContext context, WidgetRef ref, Future<void> Function() act, String done, {bool families = false}) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await act();
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(apiErrorMessage(e))));
    }
    ref.invalidate(familyProvider);
    if (families) ref.read(familiesProvider.notifier).refresh().ignore();
  }

  Future<void> _reset(BuildContext context, WidgetRef ref) async {
    final name = user.name;
    final ok = await _confirm(
      context,
      title: "Reset $name's account?",
      body: 'Use this only if $name lost every device. All of their devices are signed out now, and you get '
          'a new one-time link for them. Their chat history comes back from the others in their chats, '
          'not from you. Everyone who chats with $name will see that you reset the account.',
      key: const Key('confirm-reset'),
      action: 'Reset account',
    );
    if (!ok || !context.mounted) return;
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
    final name = user.name, family = this.family;
    final ok = await _confirm(
      context,
      title: 'Make $name an admin?',
      body: '$name will be able to invite people to ${family.name}, reset accounts (including yours) and make '
          'other admins.',
      key: const Key('confirm-admin'),
      action: 'Make admin',
      danger: false,
    );
    if (!ok || !context.mounted) return;
    final admin = ref.read(adminServiceProvider);
    if (admin == null) return;
    await _run(context, ref, () => admin.makeAdmin(user.id, familyId: family.id), '$name is now an admin');
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final name = user.name, family = this.family;
    final ok = await _confirm(
      context,
      title: 'Remove $name from ${family.name}?',
      body: "$name leaves ${family.name}'s group chats. Their account stays, with their other families. "
          'To let $name back in later, send a new invite.',
      key: const Key('confirm-remove'),
      action: 'Remove',
    );
    if (!ok || !context.mounted) return;
    await _run(
      context,
      ref,
      () => ref.read(apiClientProvider).leaveOrRemove(family.id, user.id),
      '$name was removed from ${family.name}',
      families: true,
    );
  }

  Future<void> _demote(BuildContext context, WidgetRef ref) async {
    final name = user.name, family = this.family;
    final ok = await _confirm(
      context,
      title: 'Remove $name as admin?',
      body: '$name stays in ${family.name} as a member, without admin powers.',
      key: const Key('confirm-demote'),
      action: 'Remove admin',
    );
    if (!ok || !context.mounted) return;
    await _run(context, ref, () => ref.read(apiClientProvider).demote(family.id, user.id), '$name is no longer an admin');
  }

  /// The operator only: deletes the whole account, in every family.
  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final name = user.name;
    final ok = await _confirm(
      context,
      title: "Delete $name's account?",
      body: "$name's devices are signed out, they leave every chat in every family, and the messages, photos "
          "and voice messages they sent are deleted from FamChat. It can't be undone. To let $name back in "
          'later, send a new invite.',
      key: const Key('confirm-delete'),
      action: 'Delete account',
    );
    if (!ok || !context.mounted) return;
    await _run(context, ref, () => ref.read(apiClientProvider).removeUser(user.id), "$name's account was deleted", families: true);
  }
}

/// App review (docs/protocol.md "Reviewer accounts"): a reusable link for app-store reviewers, and
/// the accounts made with it. Reviewers only ever see each other, never the family.
class _ReviewerSection extends ConsumerWidget {
  const _ReviewerSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return switch (ref.watch(reviewersProvider)) {
      AsyncData(value: final r) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SettingsGroup(title: 'App review', children: [
            if (r.inviteUrl case final url?)
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.lg, Space.lg, Space.lg, Space.sm),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('Reviewer invite', style: theme.textTheme.titleMedium),
                  const SizedBox(height: Space.xs),
                  Text(
                    'Anyone with this link can make a reviewer account, as often as they like, until you '
                    'revoke it. Reviewers only see each other, never the family.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: Space.md),
                  SelectableText(url, key: const Key('reviewer-link'), style: theme.textTheme.bodyMedium),
                  const SizedBox(height: Space.sm),
                  Wrap(alignment: WrapAlignment.end, spacing: Space.sm, children: [
                    TextButton.icon(
                      key: const Key('revoke-reviewer-invite'),
                      icon: const Icon(Icons.link_off_rounded),
                      style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                      onPressed: () => _revoke(context, ref),
                      label: const Text('Revoke'),
                    ),
                    FilledButton.tonalIcon(
                      key: const Key('copy-reviewer-link'),
                      icon: const Icon(Icons.copy_rounded),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: url));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
                        }
                      },
                      label: const Text('Copy link'),
                    ),
                  ]),
                ]),
              )
            else
              ListTile(
                key: const Key('create-reviewer-invite'),
                leading: const TileIcon(Icons.verified_user_outlined),
                title: const Text('Create reviewer invite'),
                subtitle: const Text('A reusable sign-in link for app-store reviewers, kept apart from the family.'),
                onTap: () => _create(context, ref),
              ),
          ]),
          if (r.users.isNotEmpty)
            SettingsGroup(
              title: 'Reviewer accounts',
              children: [for (final u in r.users) _ReviewerTile(user: u)],
            ),
        ]),
      AsyncError() => SettingsGroup(title: 'App review', children: [
          ListTile(
            leading: const TileIcon(Icons.cloud_off_rounded),
            title: const Text("Couldn't load reviewer access"),
            trailing: TextButton(onPressed: () => ref.invalidate(reviewersProvider), child: const Text('Retry')),
          ),
        ]),
      _ => const SizedBox.shrink(),
    };
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(apiClientProvider).createReviewerInvite();
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(apiErrorMessage(e))));
    }
    ref.invalidate(reviewersProvider);
  }

  Future<void> _revoke(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revoke the reviewer invite?'),
        content: const Text(
          'Nobody can make a new reviewer account with this link any more. Reviewer accounts that '
          'already exist keep working until you remove them.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('confirm-revoke-reviewer'),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(apiClientProvider).revokeReviewerInvite();
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(apiErrorMessage(e))));
    }
    ref.invalidate(reviewersProvider);
  }
}

class _ReviewerTile extends ConsumerWidget {
  const _ReviewerTile({required this.user});

  final ReviewerAccount user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = user.devices;
    return ListTile(
      key: Key('reviewer-user-${user.id}'),
      leading: PersonAvatar(label: user.name, colorKey: user.id, userId: user.id),
      title: Text(user.name),
      subtitle: Text(n == 0 ? 'No devices' : '$n ${n == 1 ? 'device' : 'devices'}'),
      trailing: IconButton(
        key: Key('remove-reviewer-${user.id}'),
        tooltip: 'Remove ${user.name}',
        icon: const Icon(Icons.person_remove_outlined),
        onPressed: () => _remove(context, ref),
      ),
    );
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final name = user.name;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove $name?'),
        content: Text(
          "$name's reviewer account is deleted with everything they sent. It can't be undone. "
          'With the reviewer invite they can make a new account.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('confirm-remove'),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(apiClientProvider).removeUser(user.id);
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$name was removed')));
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(apiErrorMessage(e))));
    }
    ref.invalidate(reviewersProvider);
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
