import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../pairing/new_device_pairing.dart';
import '../pairing/pair_code.dart';
import '../pairing/pairing_providers.dart';
import '../platform_info.dart';
import '../session/session_controller.dart';
import '../widgets/onboarding_frame.dart';
import '../widgets/pair_qr_view.dart';

/// "Sign in with another device": this device shows a QR code and a typeable code, or scans/types
/// one shown by the other device (Add a device → Show a code); a device where the user is signed in
/// approves it and hands over the keys and history.
class PairScreen extends ConsumerStatefulWidget {
  const PairScreen({super.key});

  @override
  ConsumerState<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends ConsumerState<PairScreen> {
  final _deviceName = TextEditingController(text: defaultDeviceName());
  final _linkCode = TextEditingController();
  NewDevicePairing? _pairing;
  StreamSubscription<PairState>? _sub;
  PairState _state = const PairIdle();
  Timer? _tick;
  String? _error;

  /// Entering (scanning or typing) the other device's code instead of showing ours.
  bool _entering = false;

  /// The current or last run took the other device's code (so "try again" goes back to entering).
  bool _viaLink = false;

  /// A rescan needs a fresh scanner (it reports once).
  int _scanGeneration = 0;

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(_sub?.cancel());
    final p = _pairing;
    if (p != null) unawaited(p.cancel().whenComplete(p.dispose));
    _deviceName.dispose();
    _linkCode.dispose();
    super.dispose();
  }

  /// The device name, or null after showing why it won't do.
  String? _name() {
    final name = _deviceName.text.trim();
    if (name.isEmpty || name.runes.length > 60) {
      setState(() => _error = 'Give this device a name (up to 60 characters).');
      return null;
    }
    return name;
  }

  /// Starts pairing: shows this device's code, or with [offer] takes the other device's code.
  Future<void> _start({PairCode? offer}) async {
    final name = _name();
    if (name == null) return;
    final old = _pairing;
    if (old != null) {
      // Not awaited: a subscription's cancel future can belong to another zone.
      unawaited(_sub?.cancel());
      unawaited(old.cancel().whenComplete(old.dispose));
    }
    final p = _pairing = newDevicePairing(ref, name);
    _sub = p.states.listen(_onState);
    setState(() {
      _error = null;
      _entering = false;
      _viaLink = offer != null;
    });
    await p.start(offer: offer);
  }

  void _enterLink() {
    if (_name() == null) return;
    setState(() {
      _error = null;
      _entering = true;
      _state = const PairIdle();
      _linkCode.clear();
      _scanGeneration++;
    });
  }

  Future<void> _connect(String input) async {
    final code = parseLinkInput(input);
    if (code == null) {
      setState(() {
        _error = "That isn't a FamChat code. It looks like XXXX-XXXX-XXXX-XXXX.";
        _scanGeneration++;
      });
      return;
    }
    await _start(offer: code);
  }

  Future<void> _onState(PairState s) async {
    if (!mounted) return;
    setState(() => _state = s);
    _tick?.cancel();
    if (s is PairShowing || s is PairJoined) {
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

  /// "Try again" / "Get a new code": a new code of ours, or back to entering the other device's.
  Future<void> _restart() async => _viaLink ? _enterLink() : _start();

  String _remaining(DateTime expiresAt) => timeLeft(expiresAt, ref.read(clockProvider)());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return OnboardingFrame(
      onBack: _entering ? () => setState(() => _entering = false) : _cancel,
      title: 'Sign in with another device',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: switch (_state) {
          PairIdle() || PairCancelled() => _entering ? _enter(theme) : _intro(theme),
          PairStarting() => [_progress(_viaLink ? 'Connecting…' : 'Getting a code…')],
          PairShowing(:final code, :final qr, :final expiresAt) => [
              Text(
                'On a phone or computer where you already use FamChat, open Devices → Add a device, '
                'then scan this code or type it in.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 24),
              PairQrView(data: qr, display: code.display, qrKey: const Key('pair-qr'), codeKey: const Key('pair-code')),
              const SizedBox(height: 8),
              _expires(theme, expiresAt),
              const SizedBox(height: 16),
              _waiting('Waiting for approval…'),
              const SizedBox(height: 24),
              OutlinedButton(onPressed: _cancel, child: const Text('Cancel')),
            ],
          PairJoined(:final expiresAt) => [
              const Center(child: Icon(Icons.phonelink_lock_rounded, size: 48)),
              const SizedBox(height: 16),
              Text(
                'Now approve "${_deviceName.text.trim()}" on your other device.',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              _expires(theme, expiresAt),
              const SizedBox(height: 16),
              _waiting('Waiting for approval…'),
              const SizedBox(height: 24),
              OutlinedButton(onPressed: _cancel, child: const Text('Cancel')),
            ],
          PairFinishing() || PairDone() => [_progress('Approved. Setting up this device…')],
          PairExpired() => [
              Text(
                _viaLink ? 'This code expired or was cancelled.' : 'This code expired.',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('pair-restart'),
                onPressed: _restart,
                child: Text(_viaLink ? 'Enter a new code' : 'Get a new code'),
              ),
            ],
          PairFailed(:final message) => [
              Text(message, textAlign: TextAlign.center, style: TextStyle(color: theme.colorScheme.error)),
              const SizedBox(height: 16),
              FilledButton(key: const Key('pair-restart'), onPressed: _restart, child: const Text('Try again')),
            ],
        },
      ),
    );
  }

  List<Widget> _intro(ThemeData theme) {
    final scanner = ref.watch(qrScannerProvider);
    return [
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
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const Key('pair-scan-start'),
        onPressed: _enterLink,
        icon: Icon(scanner == null ? Icons.keyboard_rounded : Icons.qr_code_scanner_rounded),
        label: Text(scanner == null ? 'Enter a code from your other device' : 'Scan a code from your other device'),
      ),
    ];
  }

  List<Widget> _enter(ThemeData theme) {
    final scanner = ref.watch(qrScannerProvider);
    return [
      Text(
        'On a phone or computer where you already use FamChat, open Devices → Add a device → Show a code. '
        '${scanner == null ? 'Then type the code it shows.' : 'Then scan it here, or type it.'}',
        style: theme.textTheme.bodyLarge,
      ),
      if (scanner != null) ...[
        const SizedBox(height: 16),
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: SizedBox(
            key: ValueKey('link-scanner-$_scanGeneration'),
            height: 280,
            child: scanner(context, _connect),
          ),
        ),
      ],
      const SizedBox(height: 16),
      TextField(
        key: const Key('link-code-field'),
        controller: _linkCode,
        autocorrect: false,
        textCapitalization: TextCapitalization.characters,
        style: const TextStyle(fontSize: 18, letterSpacing: 1.5, fontFeatures: [FontFeature.tabularFigures()]),
        decoration: const InputDecoration(labelText: 'Code', hintText: 'XXXX-XXXX-XXXX-XXXX'),
        onSubmitted: _connect,
      ),
      if (_error != null) ...[
        const SizedBox(height: 8),
        Text(_error!, key: const Key('link-error'), style: TextStyle(color: theme.colorScheme.error)),
      ],
      const SizedBox(height: 16),
      FilledButton(key: const Key('link-connect'), onPressed: () => _connect(_linkCode.text), child: const Text('Connect')),
      const SizedBox(height: 8),
      TextButton(onPressed: () => setState(() => _entering = false), child: const Text('Back')),
    ];
  }

  Widget _expires(ThemeData theme, DateTime expiresAt) => Text(
        'Expires in ${_remaining(expiresAt)}',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );

  Widget _waiting(String text) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Flexible(child: Text(text)),
        ],
      );

  Widget _progress(String text) => Column(children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(text, textAlign: TextAlign.center),
      ]);
}
