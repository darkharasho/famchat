import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../api/models.dart';
import '../session/session_controller.dart';
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

IconData _platformIcon(String p) => switch (p) {
      'ios' || 'android' => Icons.smartphone,
      'web' => Icons.language,
      _ => Icons.computer,
    };

/// This user's signed-in devices; revoke others, or sign this one out.
class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key});

  Future<void> _revoke(BuildContext context, WidgetRef ref, DeviceInfo d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Revoke ${d.name}?'),
        content: const Text('It will be signed out right away and its keys will stop working.'),
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
        leading: BackButton(onPressed: () => context.go('/')),
        title: const Text('Devices'),
      ),
      body: devices.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(apiErrorMessage(e)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: () => ref.invalidate(devicesProvider), child: const Text('Try again')),
          ]),
        ),
        data: (list) => RefreshIndicator(
          onRefresh: () => ref.refresh(devicesProvider.future),
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              for (final d in list)
                ListTile(
                  leading: Icon(_platformIcon(d.platform)),
                  title: Text(d.name),
                  subtitle: Text(
                    '${_platformLabels[d.platform] ?? d.platform} · Last seen ${loc.formatMediumDate(d.lastSeen)}',
                  ),
                  trailing: d.current
                      ? const Chip(label: Text('This device'))
                      : TextButton(onPressed: () => _revoke(context, ref, d), child: const Text('Revoke')),
                ),
              const SizedBox(height: 24),
              Center(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.logout),
                  label: const Text('Sign out of this device'),
                  onPressed: () => confirmSignOut(context, ref),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
