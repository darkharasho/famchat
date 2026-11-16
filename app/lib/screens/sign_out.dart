import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../api/models.dart';
import '../session/session_controller.dart';

/// Asks, then signs this device out (the router returns to the join screen).
Future<void> confirmSignOut(BuildContext context, WidgetRef ref) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Sign out?'),
      content: const Text(
        "This device's keys will be deleted. If it's your only device, you'll need a new invite to get back in.",
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sign out')),
      ],
    ),
  );
  if (ok == true) await ref.read(sessionProvider.notifier).signOut();
}

/// A short message for an error from an API call on a signed-in screen.
String apiErrorMessage(Object e) => switch (e) {
      // Shown only for a moment: the router moves to the join screen.
      SignedOutException() => 'Signed out.',
      NetworkException() => "Couldn't reach FamChat. Check your connection and try again.",
      ApiException(code: 'forbidden') => "You don't have permission to do that.",
      ApiException(:final code) => 'Something went wrong ($code). Please try again.',
      _ => 'Something went wrong. Please try again.',
    };
