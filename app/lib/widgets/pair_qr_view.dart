import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../theme/tokens.dart';

/// A pairing QR code on a white card (codes scan best dark on light, in either theme), with the
/// typeable code under it.
class PairQrView extends StatelessWidget {
  const PairQrView({super.key, required this.data, required this.display, required this.qrKey, required this.codeKey});

  /// The QR's text.
  final String data;

  /// The same code to type, as XXXX-XXXX-XXXX-XXXX.
  final String display;
  final Key qrKey, codeKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(Radii.lg),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            padding: const EdgeInsets.all(Space.lg),
            child: QrImageView(
              key: qrKey,
              data: data,
              size: 220,
              eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF2E2550)),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: Color(0xFF2E2550),
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        SelectableText(
          display,
          key: codeKey,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(
            letterSpacing: 2,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// "m:ss" left until [expiresAt] at [now] (0:00 once past).
String timeLeft(DateTime expiresAt, DateTime now) {
  final left = expiresAt.difference(now);
  if (left.isNegative) return '0:00';
  return '${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}';
}
