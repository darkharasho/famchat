// A signed-in person opened an invite link: offer to join that family
// (docs/protocol.md "Families": invite-lookup, join).
import 'package:material_ui/material_ui.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import 'sign_out.dart';

/// Looks [token] up and, when it's usable, asks whether to join. [sheetContext] must sit under the
/// root Navigator; [messenger] shows the outcome; [onJoined] runs after a successful join.
Future<void> offerToJoinFamily({
  required ApiClient api,
  required BuildContext Function() sheetContext,
  required ScaffoldMessengerState? messenger,
  required String token,
  required VoidCallback onJoined,
}) async {
  void say(String m) => messenger?.showSnackBar(SnackBar(content: Text(m)));
  final InviteLookup lookup;
  try {
    lookup = await api.lookupInvite(token);
  } catch (e) {
    say(e is ApiException && e.code == 'invite_invalid' ? _expired : apiErrorMessage(e));
    return;
  }
  if (lookup.alreadyMember) {
    say("You're already in ${lookup.familyName}");
    return;
  }
  final BuildContext context;
  try {
    context = sheetContext();
  } catch (_) {
    return;
  }
  if (!context.mounted) return;
  // onJoined runs from the sheet itself, so a dismissal mid-join can't skip it.
  await showModalBottomSheet<bool>(
    context: context,
    builder: (_) => _JoinSheet(lookup: lookup, token: token, api: api, say: say, onJoined: onJoined),
  );
}

const _expired = 'This invite link has expired or was already used.';

class _JoinSheet extends StatefulWidget {
  const _JoinSheet({required this.lookup, required this.token, required this.api, required this.say, required this.onJoined});
  final InviteLookup lookup;
  final String token;
  final ApiClient api;
  final void Function(String) say;
  final VoidCallback onJoined;

  @override
  State<_JoinSheet> createState() => _JoinSheetState();
}

class _JoinSheetState extends State<_JoinSheet> {
  bool _busy = false;

  Future<void> _join() async {
    if (_busy) return;
    setState(() => _busy = true);
    final name = widget.lookup.familyName;
    bool joined = false;
    try {
      await widget.api.joinFamily(widget.lookup.familyId, widget.token);
      widget.say('You joined $name');
      joined = true;
      widget.onJoined();
    } catch (e) {
      widget.say(switch (e) {
        ApiException(code: 'conflict') => "You're already in $name",
        ApiException(code: 'invite_invalid') => _expired,
        ApiException(code: 'admin_invite') => 'This invite is for a new person. Ask for a member invite instead.',
        _ => apiErrorMessage(e),
      });
    }
    if (mounted) Navigator.of(context).pop(joined);
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.lookup.familyName;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Join $name?', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            FilledButton(onPressed: _busy ? null : _join, child: const Text('Join')),
            const SizedBox(height: 8),
            TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Not now')),
          ],
        ),
      ),
    );
  }
}
