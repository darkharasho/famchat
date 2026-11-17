// The operator's screen: the families waiting for approval, and app review access. Only the
// operator gets here (Settings shows the tile to them alone, and the screen sends anyone else back).
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../admin/admin_providers.dart';
import '../api/models.dart';
import '../session/session_controller.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import '../widgets/person_avatar.dart';
import 'account_providers.dart';
import 'sign_out.dart';

class OperatorScreen extends ConsumerWidget {
  const OperatorScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    final back = BackButton(onPressed: () => context.go('/settings'));
    // Not the operator: back to Settings (a deep link opens this before /me has loaded).
    if (me.hasValue && me.value?.operator != true) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.go('/settings');
      });
    }
    if (me.value?.operator != true) {
      return Scaffold(appBar: AppBar(leading: back, title: const Text('Family requests')), body: const SizedBox.shrink());
    }
    return Scaffold(
      appBar: AppBar(
        leading: back,
        title: const Text('Family requests'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => ref
              ..invalidate(operatorRequestsProvider)
              ..invalidate(reviewersProvider),
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.only(top: Space.sm, bottom: Space.xxl + MediaQuery.paddingOf(context).bottom),
        children: const [
          ContentWidth(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _Requests(),
              ReviewerSection(),
            ]),
          ),
        ],
      ),
    );
  }
}

class _Requests extends ConsumerWidget {
  const _Requests();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(operatorRequestsProvider)) {
      AsyncData(value: final requests) => SettingsGroup(
          title: 'Waiting for approval',
          children: requests.isEmpty
              ? const [ListTile(title: Text('No requests waiting'))]
              : [for (final r in requests) _RequestTile(request: r)],
        ),
      AsyncError() => SettingsGroup(title: 'Waiting for approval', children: [
          ListTile(
            leading: const TileIcon(Icons.cloud_off_rounded),
            title: const Text("Couldn't load the requests"),
            trailing: TextButton(onPressed: () => ref.invalidate(operatorRequestsProvider), child: const Text('Retry')),
          ),
        ]),
      _ => const Padding(padding: EdgeInsets.all(Space.xl), child: Center(child: CircularProgressIndicator())),
    };
  }
}

class _RequestTile extends ConsumerWidget {
  const _RequestTile({required this.request});

  final FamilyRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final date = MaterialLocalizations.of(context).formatMediumDate(request.createdAt);
    final by = request.creatorName;
    return ListTile(
      key: Key('family-request-${request.id}'),
      leading: const TileIcon(Icons.diversity_3_rounded),
      title: Text(request.name),
      subtitle: Text(by == null ? 'Requested on $date' : 'Requested by $by on $date'),
      trailing: Wrap(spacing: Space.xs, children: [
        TextButton(
          key: Key('decline-family-${request.id}'),
          style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
          onPressed: () => _decline(context, ref),
          child: const Text('Decline'),
        ),
        FilledButton(
          key: Key('approve-family-${request.id}'),
          onPressed: () => _decide(context, ref, approve: true),
          child: const Text('Approve'),
        ),
      ]),
    );
  }

  Future<void> _decline(BuildContext context, WidgetRef ref) async {
    final name = request.name;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Decline $name?'),
        content: Text('$name stays unapproved: nobody can be invited to it. Whoever asked sees that it was declined.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('confirm-decline'),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Decline'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await _decide(context, ref, approve: false);
  }

  Future<void> _decide(BuildContext context, WidgetRef ref, {required bool approve}) async {
    final messenger = ScaffoldMessenger.of(context);
    final api = ref.read(apiClientProvider);
    final container = ProviderScope.containerOf(context); // the tile may go before the call returns
    try {
      await (approve ? api.approveFamily(request.id) : api.declineFamily(request.id));
      messenger.showSnackBar(SnackBar(content: Text(approve ? '${request.name} was approved' : '${request.name} was declined')));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.code == 'conflict' ? 'Already decided.' : apiErrorMessage(e))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(apiErrorMessage(e))));
    }
    container.invalidate(operatorRequestsProvider);
  }
}

/// App review (docs/protocol.md "Reviewer accounts"): a reusable link for app-store reviewers, and
/// the accounts made with it. Reviewers only ever see each other, never the family.
class ReviewerSection extends ConsumerWidget {
  const ReviewerSection({super.key});

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

