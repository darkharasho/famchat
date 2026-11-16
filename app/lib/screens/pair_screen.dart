import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../pairing/new_device_pairing.dart';
import '../pairing/pairing_providers.dart';
import '../platform_info.dart';
import '../session/session_controller.dart';
import '../theme/tokens.dart';
import '../widgets/onboarding_frame.dart';

/// "Sign in with another device": this device shows a QR code and a typeable code; a device where
/// the user is signed in approves it and hands over the keys and history.
class PairScreen extends ConsumerStatefulWidget {
  const PairScreen({super.key});

  @override
  ConsumerState<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends ConsumerState<PairScreen> {
  final _deviceName = TextEditingController(text: defaultDeviceName());
  NewDevicePairing? _pairing;
  StreamSubscription<PairState>? _sub;
  PairState _state = const PairIdle();
  Timer? _tick;
  String? _error;

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(_sub?.cancel());
    final p = _pairing;
    if (p != null) unawaited(p.cancel().whenComplete(p.dispose));
    _deviceName.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final name = _deviceName.text.trim();
    if (name.isEmpty || name.runes.length > 60) {
      setState(() => _error = 'Give this device a name (up to 60 characters).');
      return;
    }
    final old = _pairing;
    if (old != null) {
      // Not awaited: a subscription's cancel future can belong to another zone.
      unawaited(_sub?.cancel());
      unawaited(old.cancel().whenComplete(old.dispose));
    }
    final p = _pairing = newDevicePairing(ref, name);
    _sub = p.states.listen(_onState);
    setState(() => _error = null);
    await p.start();
  }

  Future<void> _onState(PairState s) async {
    if (!mounted) return;
    setState(() => _state = s);
    _tick?.cancel();
    if (s is PairShowing) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
    if (s is PairDone) {
      try {
        await finishPairing(ref, s.device);
        // The router moves on to the chats.
      } catch (_) {
        if (mounted) {
          setState(() => _state = const PairFailed("Couldn't save your keys on this device. Please try again."));
        }
      }
    }
  }

  Future<void> _cancel() async {
    await _pairing?.cancel();
    if (mounted) context.go('/join');
  }

  String _remaining(DateTime expiresAt) {
    final left = expiresAt.difference(ref.read(clockProvider)());
    if (left.isNegative) return '0:00';
    return '${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return OnboardingFrame(
      onBack: _cancel,
      title: 'Sign in with another device',
      child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: switch (_state) {
                  PairIdle() || PairCancelled() => _intro(theme),
                  PairStarting() => [_progress('Getting a code…')],
                  PairShowing(:final code, :final qr, :final expiresAt) => [
                      Text(
                        'On a phone or computer where you already use FamChat, open Devices → Add a device, '
                        'then scan this code or type it in.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 24),
                      Center(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white, // QR codes scan best dark on light, in either theme
                            borderRadius: BorderRadius.circular(Radii.lg),
                            border: Border.all(color: theme.colorScheme.outlineVariant),
                          ),
                          padding: const EdgeInsets.all(Space.lg),
                          child: QrImageView(
                            key: const Key('pair-qr'),
                            data: qr,
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
                        code.display,
                        key: const Key('pair-code'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          letterSpacing: 2,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Expires in ${_remaining(expiresAt)}',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 16),
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                          SizedBox(width: 12),
                          Text('Waiting for approval…'),
                        ],
                      ),
                      const SizedBox(height: 24),
                      OutlinedButton(onPressed: _cancel, child: const Text('Cancel')),
                    ],
                  PairFinishing() || PairDone() => [_progress('Approved. Setting up this device…')],
                  PairExpired() => [
                      Text('This code expired.', textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 16),
                      FilledButton(key: const Key('pair-restart'), onPressed: _start, child: const Text('Get a new code')),
                    ],
                  PairFailed(:final message) => [
                      Text(message, textAlign: TextAlign.center, style: TextStyle(color: theme.colorScheme.error)),
                      const SizedBox(height: 16),
                      FilledButton(key: const Key('pair-restart'), onPressed: _start, child: const Text('Try again')),
                    ],
                },
      ),
    );
  }

  List<Widget> _intro(ThemeData theme) => [
        Text(
          'Already use FamChat on another phone or computer? Approve this device from there, '
          'and it gets your chats and their history.',
          style: theme.textTheme.bodyLarge,
        ),
        const SizedBox(height: 24),
        TextField(
          key: const Key('pair-device-name'),
          controller: _deviceName,
          maxLength: 60,
          decoration: const InputDecoration(
            labelText: 'Name for this device',
            helperText: 'Shown on the device that approves it.',
            prefixIcon: Icon(Icons.smartphone_rounded),
          ),
          onSubmitted: (_) => _start(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 16),
        FilledButton(key: const Key('pair-start'), onPressed: _start, child: const Text('Show my code')),
      ];

  Widget _progress(String text) => Column(children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(text, textAlign: TextAlign.center),
      ]);
}
