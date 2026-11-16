import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../session/session_controller.dart';
import '../theme/palette.dart';
import '../theme/tokens.dart';
import '../widgets/brand_mark.dart';
import '../widgets/onboarding_frame.dart';

/// Shown while the saved session loads, or when secure storage can't be opened.
class LoadingScreen extends ConsumerWidget {
  const LoadingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    if (s is! SessionUnavailable) {
      // Continues the launch screen: the mark on dusk.
      return const Scaffold(
        backgroundColor: Palette.dusk,
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            BrandMark(size: 72, rim: false),
            SizedBox(height: Space.xxl),
            SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: Palette.amber),
            ),
          ]),
        ),
      );
    }
    final theme = Theme.of(context);
    return OnboardingFrame(
      title: "Can't open FamChat's keys",
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Icon(Icons.lock_outline_rounded, size: 40, color: theme.colorScheme.error),
        const SizedBox(height: Space.lg),
        Text(s.message, textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
        const SizedBox(height: Space.xl),
        FilledButton(
          onPressed: () => ref.read(sessionProvider.notifier).retryRestore(),
          child: const Text('Try again'),
        ),
        const SizedBox(height: Space.sm),
        TextButton(onPressed: () => _startOver(context, ref), child: const Text('Start over')),
      ]),
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
