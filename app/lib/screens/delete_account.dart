// Deleting your own account (Settings) and removing someone from the family (admin, Family
// screen). Both delete the account on the server: docs/protocol.md "Deleting an account".
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../api/models.dart';
import '../session/session_controller.dart';
import '../theme/tokens.dart';
import 'sign_out.dart';

/// What the user types to confirm deleting their account.
const deleteConfirmWord = 'DELETE';

/// Asks (type-to-confirm), deletes the account on the server, then wipes this device; the router
/// returns to the join screen. Errors are shown in the dialog and nothing changes.
Future<void> confirmDeleteAccount(BuildContext context, WidgetRef ref) async {
  final deleted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const _DeleteAccountDialog(),
  );
  if (deleted == true) await ref.read(sessionProvider.notifier).accountDeleted();
}

/// Error text for a failed account deletion.
String deleteAccountErrorMessage(Object e) => switch (e) {
      ApiException(code: 'last_admin') =>
        "You're the family's only admin. Make someone else an admin first (Settings → Family members).",
      _ => apiErrorMessage(e),
    };

class _DeleteAccountDialog extends ConsumerStatefulWidget {
  const _DeleteAccountDialog();

  @override
  ConsumerState<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends ConsumerState<_DeleteAccountDialog> {
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  bool get _typed => _confirm.text.trim().toUpperCase() == deleteConfirmWord;

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).deleteAccount();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = deleteAccountErrorMessage(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    return AlertDialog(
      title: const Text('Delete your account?'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text(
            'This permanently deletes your FamChat account:\n'
            '• your name and your place in the family\n'
            '• every device you are signed in on\n'
            '• the messages, photos and voice messages you sent\n'
            '• you leave all of your chats',
          ),
          const SizedBox(height: Space.md),
          Text(
            "It can't be undone. Copies already on other family members' devices stay there. "
            'To come back later you need a new invite.',
            style: theme.textTheme.bodyMedium?.copyWith(color: s.onSurfaceVariant),
          ),
          const SizedBox(height: Space.lg),
          TextField(
            key: const Key('delete-account-confirm-field'),
            controller: _confirm,
            enabled: !_busy,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Type $deleteConfirmWord to confirm',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (_typed && !_busy) _delete();
            },
          ),
          if (_error != null) ...[
            const SizedBox(height: Space.md),
            Text(_error!, key: const Key('delete-account-error'), style: TextStyle(color: s.error)),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          key: const Key('confirm-delete-account'),
          style: FilledButton.styleFrom(backgroundColor: s.error, foregroundColor: s.onError),
          onPressed: _typed && !_busy ? _delete : null,
          child: _busy
              ? SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: s.onError))
              : const Text('Delete account'),
        ),
      ],
    );
  }
}
