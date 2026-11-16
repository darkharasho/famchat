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
                  ]),
                ),
              )
            : const CircularProgressIndicator(),
      ),
    );
  }
}
