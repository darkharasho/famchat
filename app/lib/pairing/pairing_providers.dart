// Riverpod wiring for pairing: the approver on a signed-in device, finishing a pairing on a new
// device, and the camera scanner (Android and iOS only; elsewhere the code is typed).
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../chat/providers.dart';
import '../platform_info.dart';
import '../session/session_controller.dart';
import 'approver.dart';
import 'bundle.dart';
import 'new_device_pairing.dart';

/// How often a new device asks whether it was approved.
final pairPollEveryProvider = Provider<Duration>((ref) => const Duration(seconds: 2));

/// A new device's pairing run (one per screen visit; [deviceName] is what the approver sees).
NewDevicePairing newDevicePairing(WidgetRef ref, String deviceName) => NewDevicePairing(
      api: ref.read(apiClientProvider),
      deviceName: deviceName,
      platform: serverPlatform(),
      pollEvery: ref.read(pairPollEveryProvider),
      now: ref.read(clockProvider),
    );

/// On the new device: stores the handed-over keys and trust, then saves the session (the router
/// moves on to the chats). Keys go in first so the chat engine finds them when it starts.
Future<void> finishPairing(WidgetRef ref, PairedDevice device) async {
  await installHandover(ref.read(chatDbProvider), device.bundle);
  await ref.read(sessionProvider.notifier).adoptSession(device.session, device.accessToken);
}

/// The approver for this signed-in device, or null when signed out.
final deviceApproverProvider = Provider<DeviceApprover?>((ref) {
  final s = ref.watch(sessionProvider);
  if (s is! SignedIn) return null;
  return DeviceApprover(api: ref.watch(apiClientProvider), db: ref.watch(chatDbProvider), session: s.session);
});

/// Builds a camera view that reports scanned text.
typedef QrScannerBuilder = Widget Function(BuildContext context, void Function(String text) onCode);

/// The camera scanner where offered (Android and iOS), else null. Tests override it.
final qrScannerProvider = Provider<QrScannerBuilder?>((ref) {
  if (kIsWeb) return null;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => (context, onCode) => CameraQrScanner(onCode: onCode),
    _ => null,
  };
});

/// The phone camera, reading QR codes only; reports the first code once.
class CameraQrScanner extends StatefulWidget {
  const CameraQrScanner({super.key, required this.onCode});
  final void Function(String text) onCode;

  @override
  State<CameraQrScanner> createState() => _CameraQrScannerState();
}

class _CameraQrScannerState extends State<CameraQrScanner> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _reported = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MobileScanner(
        controller: _controller,
        onDetect: (capture) {
          final text = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
          if (text == null || _reported) return;
          _reported = true;
          widget.onCode(text);
        },
        errorBuilder: (context, error) => Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              "The camera isn't available (${error.errorCode.name}). Type the code instead.",
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
}
