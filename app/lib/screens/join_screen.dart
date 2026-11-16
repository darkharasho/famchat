import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../api/models.dart';
import '../platform_info.dart';
import '../session/invite_link.dart';
import '../session/session_controller.dart';

/// First launch: redeem an invite link, creating this user's keys and first device.
class JoinScreen extends ConsumerStatefulWidget {
  const JoinScreen({super.key});

  @override
  ConsumerState<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends ConsumerState<JoinScreen> {
  final _invite = TextEditingController();
  final _deviceName = TextEditingController(text: defaultDeviceName());
  String? _linkToken;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _linkToken = ref.read(initialInviteTokenProvider);
  }

  @override
  void dispose() {
    _invite.dispose();
    _deviceName.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final token = _linkToken ?? parseInviteToken(_invite.text);
    final name = _deviceName.text.trim();
    String? error;
    if (token == null) {
      error = "That doesn't look like a FamChat invite link.";
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
      await ref.read(sessionProvider.notifier).join(token: token, deviceName: name);
      // The router moves on to the home screen.
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _message(Object e) => switch (e) {
        ApiException(code: 'invite_invalid') => 'This invite has expired or was already used. Ask for a new one.',
        ApiException(code: 'invalid_request') => 'FamChat refused this request. Check the link and the device name.',
        ApiException(:final code) => 'Something went wrong ($code). Please try again.',
        NetworkException() => "Couldn't reach FamChat. Check your connection and try again.",
        _ => "Couldn't save your keys on this device. Please try again.",
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = ref.watch(sessionProvider);
    final notice = session is SignedOut ? session.message : null;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.forum_rounded, size: 56, color: theme.colorScheme.primary),
                  const SizedBox(height: 16),
                  Text('Join FamChat', textAlign: TextAlign.center, style: theme.textTheme.headlineMedium),
                  const SizedBox(height: 8),
                  Text(
                    _linkToken == null
                        ? 'Paste the invite link someone in your family sent you.'
                        : 'Joining with the invite link you opened.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (notice != null) ...[
                    const SizedBox(height: 16),
                    Card(
                      color: theme.colorScheme.secondaryContainer,
                      child: Padding(padding: const EdgeInsets.all(12), child: Text(notice)),
                    ),
                  ],
                  const SizedBox(height: 24),
                  if (_linkToken == null)
                    TextField(
                      key: const Key('invite-field'),
                      controller: _invite,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        labelText: 'Invite link',
                        hintText: 'https://famchat.dev/join#…',
                        border: OutlineInputBorder(),
                      ),
                      autocorrect: false,
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
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('device-name-field'),
                    controller: _deviceName,
                    enabled: !_busy,
                    maxLength: 60,
                    decoration: const InputDecoration(
                      labelText: 'Name for this device',
                      helperText: 'So you can tell your devices apart.',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _join(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                  ],
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const Key('join-button'),
                    onPressed: _busy ? null : _join,
                    child: _busy
                        ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Join'),
                  ),
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    key: const Key('pair-link'),
                    onPressed: _busy ? null : () => context.go('/pair'),
                    icon: const Icon(Icons.qr_code_2_rounded),
                    label: const Text('Sign in with another device'),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Already use FamChat on a phone or computer? Approve this device from there.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 32),
                  TextButton(
                    onPressed: () => context.go('/spikes'),
                    child: const Text('Platform spikes'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
