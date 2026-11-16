import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../api/models.dart';
import '../push/providers.dart';
import '../push/push_messaging.dart';
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

String platformLabel(String p) => _platformLabels[p] ?? p;

IconData _platformIcon(String p) => switch (p) {
      'ios' || 'android' => Icons.smartphone,
      'web' => Icons.language,
      _ => Icons.computer,
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

  Future<void> _testPush(BuildContext context, WidgetRef ref) async {
    String text;
    try {
      // Make sure this device's token is registered first (permission may have been granted since).
      await ref.read(pushControllerProvider)?.enable();
      text = pushTestSummary(await ref.read(apiClientProvider).authedJson('POST', '/devices/me/push/test'));
    } catch (e) {
      text = apiErrorMessage(e);
    }
    if (context.mounted) _snack(context, text);
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
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add-device'),
        onPressed: () => context.go('/devices/add'),
        icon: const Icon(Icons.add),
        label: const Text('Add a device'),
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
                    '${platformLabel(d.platform)} · Last seen ${loc.formatMediumDate(d.lastSeen)}',
                  ),
                  trailing: d.current
                      ? const Chip(label: Text('This device'))
                      : TextButton(onPressed: () => _revoke(context, ref, d), child: const Text('Revoke')),
                ),
              const SizedBox(height: 24),
              if (ref.watch(pushMessagingProvider) != null)
                Center(
                  child: TextButton.icon(
                    icon: const Icon(Icons.notifications_active_outlined),
                    label: const Text('Send a test notification'),
                    onPressed: () => _testPush(context, ref),
                  ),
                ),
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

/// One line about the answer of `POST /devices/me/push/test`.
String pushTestSummary(Map<String, Object?>? body) {
  if (body == null || body['configured'] != true) return "Push isn't set up on the server yet.";
  if (body['error'] != null) return "The server couldn't reach Firebase.";
  final devices = (body['devices'] as List? ?? const []).cast<Map<String, Object?>>();
  if (devices.isEmpty) return 'None of your devices has notifications turned on.';
  final ok = devices.where((d) => d['result'] == 'ok').length;
  final failed = [for (final d in devices) if (d['result'] != 'ok') d['name'] ?? 'a device'];
  final sent = 'Sent to $ok of ${devices.length} device${devices.length == 1 ? '' : 's'}.';
  return failed.isEmpty ? sent : '$sent Not delivered: ${failed.join(', ')}.';
}
