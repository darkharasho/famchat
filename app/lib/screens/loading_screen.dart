import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../session/session_controller.dart';

/// Shown while the saved session loads, or when secure storage can't be opened.
class LoadingScreen extends ConsumerWidget {
  const LoadingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    return Scaffold(
      body: Center(
        child: s is SessionUnavailable
            ? ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.lock_outline, size: 48, color: Theme.of(context).colorScheme.error),
                    const SizedBox(height: 16),
                    Text(s.message, textAlign: TextAlign.center),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: () => ref.read(sessionProvider.notifier).retryRestore(),
                      child: const Text('Try again'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(onPressed: () => _startOver(context, ref), child: const Text('Start over')),
                  ]),
                ),
              )
            : const CircularProgressIndicator(),
      ),
    );
  }

  Future<void> _startOver(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Start over?'),
        content: const Text(
          "This deletes what FamChat saved on this device, including its keys. You'll need a new "
          'invite to sign in again.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Start over')),
        ],
      ),
    );
    if (ok == true) await ref.read(sessionProvider.notifier).startOver();
  }
}
