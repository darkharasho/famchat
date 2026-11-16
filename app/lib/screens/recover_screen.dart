// Signed out: get back into an admin account with the printed admin recovery code.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../api/models.dart';
import '../crypto/reset.dart';
import '../platform_info.dart';
import '../session/session_controller.dart';
import '../widgets/onboarding_frame.dart';

class RecoverScreen extends ConsumerStatefulWidget {
  const RecoverScreen({super.key});

  @override
  ConsumerState<RecoverScreen> createState() => _RecoverScreenState();
}

class _RecoverScreenState extends ConsumerState<RecoverScreen> {
  final _code = TextEditingController();
  final _deviceName = TextEditingController(text: defaultDeviceName());
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _deviceName.dispose();
    super.dispose();
  }

  Future<void> _recover() async {
    final code = RecoveryCode.parse(_code.text);
    final name = _deviceName.text.trim();
    String? error;
    if (code == null) {
      error = 'A recovery code has 25 letters and numbers, like XXXXX-XXXXX-XXXXX-XXXXX-XXXXX.';
    } else if (name.isEmpty || name.runes.length > 60) {
      error = 'Give this device a name (up to 60 characters).';
    }
    if (error != null || code == null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider.notifier).recover(code: code, deviceName: name);
      // The router moves on to the home screen.
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _message(Object e) => switch (e) {
        ApiException(code: 'unauthorized') =>
          "That code doesn't match an admin account. It may have been used already or replaced by a newer one.",
        ApiException(code: 'conflict') => 'The account changed while recovering. Please try again.',
        ApiException(:final code) => 'Something went wrong ($code). Please try again.',
        NetworkException() => "Couldn't reach FamChat. Check your connection and try again.",
        _ => "Couldn't save your keys on this device. Please try again.",
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return OnboardingFrame(
      onBack: () => context.go('/join'),
      title: 'Recover admin account',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(
                'Type the admin recovery code you printed. Your old devices will be signed out, and your '
                'chats come back from the rest of the family. The code works once.',
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 24),
              TextField(
                key: const Key('recovery-code-field'),
                controller: _code,
                enabled: !_busy,
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.characters,
                style: const TextStyle(letterSpacing: 1.2, fontFeatures: [FontFeature.tabularFigures()]),
                decoration: const InputDecoration(
                  labelText: 'Recovery code',
                  hintText: 'XXXXX-XXXXX-XXXXX-XXXXX-XXXXX',
                  prefixIcon: Icon(Icons.key_rounded),
                ),
                onSubmitted: (_) => _recover(),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('recover-device-name'),
                controller: _deviceName,
                enabled: !_busy,
                maxLength: 60,
                decoration: const InputDecoration(
                  labelText: 'Name for this device',
                  prefixIcon: Icon(Icons.smartphone_rounded),
                ),
                onSubmitted: (_) => _recover(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('recover-button'),
                onPressed: _busy ? null : _recover,
                child: _busy
                    ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Recover'),
              ),
            ]),
    );
  }
}
