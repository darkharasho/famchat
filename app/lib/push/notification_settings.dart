// The Settings page's "Notifications" group: turn them on (web, where the browser only asks after a
// click) and send a test push to your own devices (once push is set up).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../screens/sign_out.dart' show apiErrorMessage;
import '../session/session_controller.dart';
import '../widgets/common.dart';
import 'providers.dart';
import 'push_messaging.dart';

class NotificationSettingsGroup extends ConsumerWidget {
  const NotificationSettingsGroup({super.key});

  Future<void> _testPush(BuildContext context, WidgetRef ref) async {
    String text;
    try {
      // Register this device's token first (permission may have been granted since start).
      await ref.read(pushControllerProvider)?.enable();
      text = pushTestSummary(await ref.read(apiClientProvider).authedJson('POST', '/devices/me/push/test'));
    } catch (e) {
      text = apiErrorMessage(e);
    }
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offer = ref.watch(notifyOfferProvider);
    final push = ref.watch(pushMessagingProvider) != null;
    if (!offer && !push) return const SizedBox.shrink();
    return SettingsGroup(title: 'Notifications', children: [
      if (offer)
        ListTile(
          key: const Key('settings-notify-on'),
          leading: const TileIcon(Icons.notifications_outlined),
          title: const Text('Turn on notifications'),
          subtitle: const Text('For new messages while FamChat is in the background'),
          onTap: () => ref.read(notifyOfferProvider.notifier).enable(),
        ),
      if (push)
        ListTile(
          key: const Key('settings-test-push'),
          leading: const TileIcon(Icons.notifications_active_outlined),
          title: const Text('Send a test notification'),
          subtitle: const Text('To your devices that allow notifications'),
          onTap: () => _testPush(context, ref),
        ),
    ]);
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
