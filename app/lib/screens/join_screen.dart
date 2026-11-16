import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../api/models.dart';
import '../platform_info.dart';
import '../session/invite_link.dart';
import '../session/session_controller.dart';
import '../dev_tools.dart';
import '../theme/tokens.dart';
import '../widgets/onboarding_frame.dart';

/// First launch: redeem an invite link, creating this user's keys and first device.
class JoinScreen extends ConsumerStatefulWidget {
  const JoinScreen({super.key});

  @override
  ConsumerState<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends ConsumerState<JoinScreen> {
  final _invite = TextEditingController();
  final _deviceName = TextEditingController(text: defaultDeviceName());
  final _displayName = TextEditingController();
  String? _linkToken;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _linkToken = ref.read(initialInviteTokenProvider);
    // A pasted reviewer link shows the name field.
    _invite.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _invite.dispose();
    _deviceName.dispose();
    _displayName.dispose();
    super.dispose();
  }

  String? get _token => _linkToken ?? parseInviteToken(_invite.text);

  /// A reviewer link (docs/protocol.md "Reviewer accounts"): the joiner picks their own name.
  bool get _reviewer {
    final t = _token;
    return t != null && isReviewerInvite(t);
  }

  Future<void> _join() async {
    final token = _token;
    final name = _deviceName.text.trim();
    final displayName = _displayName.text.trim();
    String? error;
    if (token == null) {
      error = "That doesn't look like a FamChat invite link.";
    } else if (_reviewer && (displayName.isEmpty || displayName.runes.length > 40)) {
      error = 'Enter your name (up to 40 characters).';
    } else if (name.isEmpty || name.runes.length > 60) {
      error = 'Give this device a name (up to 60 characters).';
    }
    if (error != null || token == null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(sessionProvider.notifier)
          .join(token: token, deviceName: name, displayName: _reviewer ? displayName : null);
      // The router moves on to the home screen.
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _message(Object e) => switch (e) {
        ApiException(code: 'invite_invalid') => 'This invite has expired or was already used. Ask for a new one.',
        ApiException(code: 'invalid_request') =>
          'FamChat refused this request. Check that you used the whole link, and the device name.',
        ApiException(:final code) => 'Something went wrong ($code). Please try again.',
        NetworkException() => "Couldn't reach FamChat. Check your connection and try again.",
        _ => "Couldn't save your keys on this device. Please try again.",
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = ref.watch(sessionProvider);
    final notice = session is SignedOut ? session.message : null;
    return OnboardingFrame(
      title: 'Join FamChat',
      subtitle: "A private home for your family's messages, photos and voice notes.",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _linkToken == null
                ? 'Paste the invite link someone in your family sent you.'
                : 'Joining with the invite link you opened.',
            style: theme.textTheme.bodyLarge,
          ),
          if (notice != null) ...[
            const SizedBox(height: Space.lg),
            Card(
              color: theme.colorScheme.secondaryContainer,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
              child: Padding(
                padding: const EdgeInsets.all(Space.lg),
                child: Text(notice, style: TextStyle(color: theme.colorScheme.onSecondaryContainer)),
              ),
            ),
          ],
          const SizedBox(height: Space.xl),
          if (_linkToken == null)
            TextField(
              key: const Key('invite-field'),
              controller: _invite,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Invite link',
                hintText: 'https://famchat.dev/join#…',
                prefixIcon: Icon(Icons.link_rounded),
              ),
              autocorrect: false,
              keyboardType: TextInputType.url,
              onSubmitted: (_) => _join(),
            )
          else
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _busy ? null : () => setState(() => _linkToken = null),
                child: const Text('Use a different link'),
              ),
            ),
          if (_reviewer) ...[
            const SizedBox(height: Space.lg),
            TextField(
              key: const Key('display-name-field'),
              controller: _displayName,
              enabled: !_busy,
              maxLength: 40,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Your name',
                helperText: 'Shown to the others you chat with.',
                prefixIcon: Icon(Icons.badge_outlined),
              ),
              onSubmitted: (_) => _join(),
            ),
          ],
          const SizedBox(height: Space.lg),
          TextField(
            key: const Key('device-name-field'),
            controller: _deviceName,
            enabled: !_busy,
            maxLength: 60,
            decoration: const InputDecoration(
              labelText: 'Name for this device',
              helperText: 'So you can tell your devices apart.',
              prefixIcon: Icon(Icons.smartphone_rounded),
            ),
            onSubmitted: (_) => _join(),
          ),
          if (_error != null) ...[
            const SizedBox(height: Space.sm),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: Space.lg),
          FilledButton(
            key: const Key('join-button'),
            onPressed: _busy ? null : _join,
            child: _busy
                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Join'),
          ),
          const OrDivider(),
          OutlinedButton.icon(
            key: const Key('pair-link'),
            onPressed: _busy ? null : () => context.go('/pair'),
            icon: const Icon(Icons.qr_code_2_rounded),
            label: const Text('Sign in with another device'),
          ),
          const SizedBox(height: Space.sm),
          Text(
            'Already use FamChat on a phone or computer? Approve this device from there.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Space.lg),
          TextButton(
            key: const Key('recover-link'),
            onPressed: _busy ? null : () => context.go('/recover'),
            child: const Text('Recover admin account'),
          ),
          if (ref.watch(developerToolsProvider))
            TextButton(
              onPressed: () => context.go('/spikes'),
              child: const Text('Platform spikes'),
            ),
        ],
      ),
    );
  }
}
