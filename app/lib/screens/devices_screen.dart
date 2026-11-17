import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../api/models.dart';
import '../session/session_controller.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import 'account_providers.dart';
import 'sign_out.dart';

const _platformLabels = {
  'ios': 'iOS',
  'android': 'Android',
  'macos': 'macOS',
  'windows': 'Windows',
  'linux': 'Linux',
  'web': 'Web',
};

String platformLabel(String p) => _platformLabels[p] ?? p;

IconData _platformIcon(String p) => switch (p) {
      'ios' || 'android' => Icons.smartphone_rounded,
      'web' => Icons.language_rounded,
      _ => Icons.computer_rounded,
    };

/// This user's signed-in devices; add one (pairing), revoke others, or sign this one out.
/// Revoking moves every chat to a new key (the server rotates; member devices create the epoch).
class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key});

  Future<void> _revoke(BuildContext context, WidgetRef ref, DeviceInfo d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Revoke ${d.name}?'),
        content: const Text(
          "It will be signed out right away. Your chats move to new keys, so it can't read anything sent after this.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Revoke')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(apiClientProvider).revokeDevice(d.id);
    } on ApiException catch (e) {
      // not_found: already revoked elsewhere; the reload shows the truth.
      if (e.code != 'not_found' && context.mounted) _snack(context, apiErrorMessage(e));
    } catch (e) {
      if (context.mounted) _snack(context, apiErrorMessage(e));
    }
    ref.invalidate(devicesProvider);
  }

  static void _snack(BuildContext context, String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(devicesProvider);
    final loc = MaterialLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go('/settings')),
        title: const Text('Devices'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add-device'),
        onPressed: () => context.go('/settings/devices/add'),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add a device'),
      ),
      body: devices.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          art: Icon(Icons.cloud_off_rounded, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
          title: "Couldn't load your devices",
          body: apiErrorMessage(e),
          action: OutlinedButton(onPressed: () => ref.invalidate(devicesProvider), child: const Text('Try again')),
        ),
        data: (list) => RefreshIndicator(
          onRefresh: () => ref.refresh(devicesProvider.future),
          child: ListView(
            padding: EdgeInsets.only(top: Space.sm, bottom: 96 + MediaQuery.paddingOf(context).bottom), // clear of the button
            children: [
              ContentWidth(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Space.xl, 0, Space.xl, Space.md),
                    child: Text(
                      'Every device here can read your chats. Revoke one you no longer use or have lost.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                  SettingsGroup(children: [
                    for (final d in list)
                      ListTile(
                        leading: TileIcon(_platformIcon(d.platform)),
                        title: Text(d.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${platformLabel(d.platform)}, last seen ${loc.formatMediumDate(d.lastSeen)}'),
                        trailing: d.current
                            ? const _ThisDevice()
                            : TextButton(onPressed: () => _revoke(context, ref, d), child: const Text('Revoke')),
                      ),
                  ]),
                  const SizedBox(height: Space.sm),
                  Center(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.logout_rounded),
                      label: const Text('Sign out of this device'),
                      onPressed: () => confirmSignOut(context, ref),
                    ),
                  ),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThisDevice extends StatelessWidget {
  const _ThisDevice();

  @override
  Widget build(BuildContext context) {
    final t = FamTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: t.badge, borderRadius: BorderRadius.circular(99)),
      child: Text(
        'This device',
        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: t.onBadge, fontWeight: FontWeight.w700),
      ),
    );
  }
}
