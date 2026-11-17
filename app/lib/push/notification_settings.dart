// The Settings page's "Notifications" group: turn them on (web, where the browser only asks after a
// click) and send a test notification: a push to your own devices (once push is set up), or on
// desktop apps, which have no push, a notification shown right here.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../screens/sign_out.dart' show apiErrorMessage;
import '../session/session_controller.dart';
import '../widgets/common.dart';
import 'local_notifier.dart';
import 'notifications.dart';
import 'preview_setting.dart';
import 'providers.dart';
import 'push_messaging.dart';

class NotificationSettingsGroup extends ConsumerWidget {
  const NotificationSettingsGroup({super.key});

  Future<void> _test(BuildContext context, WidgetRef ref) async {
    String text;
    try {
      text = await runNotificationTest(
        push: ref.read(pushControllerProvider),
        local: ref.read(localNotifierProvider),
        sendServerTest: () => ref.read(apiClientProvider).authedJson('POST', '/devices/me/push/test'),
      );
    } catch (e) {
      text = apiErrorMessage(e);
    }
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Stores the value, then (Android, where push is set up) tells the server. Offline, the stored
  /// value stands and the next registration carries it.
  Future<void> _setPreviews(WidgetRef ref, bool on) async {
    await ref.read(previewsOnProvider.notifier).set(on);
    await ref.read(pushControllerProvider)?.setPreviews(on);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offer = ref.watch(notifyOfferProvider);
    final push = ref.watch(pushMessagingProvider) != null;
    final local = ref.watch(localNotifierProvider) != null;
    if (!offer && !push && !local) return const SizedBox.shrink();
    return SettingsGroup(title: 'Notifications', children: [
      if (offer)
        ListTile(
          key: const Key('settings-notify-on'),
          leading: const TileIcon(Icons.notifications_outlined),
          title: const Text('Turn on notifications'),
          subtitle: const Text('For new messages while FamChat is in the background'),
          onTap: () => ref.read(notifyOfferProvider.notifier).enable(),
        ),
      if (push || local)
        ListTile(
          key: const Key('settings-test-push'),
          leading: const TileIcon(Icons.notifications_active_outlined),
          title: const Text('Send a test notification'),
          subtitle: Text(push ? 'To your devices that allow notifications' : 'On this device'),
          onTap: () => _test(context, ref),
        ),
      if ((push || local) && previewsSupported())
        SwitchListTile(
          key: const Key('settings-previews'),
          secondary: const TileIcon(Icons.chat_bubble_outline),
          title: const Text('Show message previews'),
          subtitle: const Text('Show what messages say. Only this device can read them.'),
          value: ref.watch(previewsOnProvider).value ?? false,
          onChanged: (on) => _setPreviews(ref, on),
        ),
    ]);
  }
}

/// Sends a test notification and says how it went. With push (phones, web), this device registers
/// first and the server pushes to all of the user's registered devices; without (desktop apps),
/// the app shows one itself.
Future<String> runNotificationTest({
  required PushController? push,
  required LocalNotifier? local,
  required Future<Map<String, Object?>?> Function() sendServerTest,
}) async {
  if (push != null) {
    // Register this device's token first (permission may have been granted since start).
    final registered = await push.enable();
    return pushTestSummary(await sendServerTest(), thisDevice: registered);
  }
  if (local == null || !await local.requestPermission()) {
    return "This device can't show notifications. Check that they're allowed for FamChat.";
  }
  await local.show(id: 0, title: 'FamChat', body: 'Test notification', route: '/chats');
  return 'Sent a test notification to this device.';
}

/// One line about the answer of `POST /devices/me/push/test`. [thisDevice]: whether the device
/// asking got a push token; when it didn't, the push can only have gone to other devices.
String pushTestSummary(Map<String, Object?>? body, {bool thisDevice = true}) {
  if (body == null || body['configured'] != true) return "Push isn't set up on the server yet.";
  final notHere = thisDevice
      ? ''
      : "This device isn't registered for notifications. Check that they're allowed for FamChat. ";
  if (body['error'] != null) return "${notHere}The server couldn't reach Firebase.";
  final devices = (body['devices'] as List? ?? const []).cast<Map<String, Object?>>();
  if (devices.isEmpty) return thisDevice ? 'None of your devices has notifications turned on.' : notHere.trim();
  final ok = devices.where((d) => d['result'] == 'ok').length;
  final failed = [for (final d in devices) if (d['result'] != 'ok') d['name'] ?? 'a device'];
  final sent = 'Sent to $ok of ${devices.length} device${devices.length == 1 ? '' : 's'}.';
  return notHere + (failed.isEmpty ? sent : '$sent Not delivered: ${failed.join(', ')}.');
}
