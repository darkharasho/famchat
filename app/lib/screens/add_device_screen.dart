import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../pairing/approver.dart';
import '../pairing/pairing_providers.dart';
import 'devices_screen.dart' show platformLabel;
import 'sign_out.dart';

/// "Add a device": scan (phones) or type the code a new device shows, check it, and approve it.
class AddDeviceScreen extends ConsumerStatefulWidget {
  const AddDeviceScreen({super.key});

  @override
  ConsumerState<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

enum _Step { enter, confirm, done }

class _AddDeviceScreenState extends ConsumerState<AddDeviceScreen> {
  final _code = TextEditingController();
  _Step _step = _Step.enter;
  PendingApproval? _pending;
  bool _busy = false;
  String? _error;

  /// A rescan needs a fresh scanner (it reports once).
  int _scanGeneration = 0;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  static String message(Object e) => switch (e) {
        PairingException(kind: PairingError.badCode) => "That isn't a pairing code. It looks like XXXX-XXXX-XXXX-XXXX.",
        PairingException(kind: PairingError.notFound) =>
          'No device is waiting with that code. Codes expire after 5 minutes; get a new one on the new device.',
        PairingException(kind: PairingError.mismatch) =>
          "This code doesn't match the device FamChat found, so it wasn't added. Check the code and try again. "
              "If it keeps happening, don't add the device.",
        _ => apiErrorMessage(e),
      };

  Future<void> _lookup(String input) async {
    final approver = ref.read(deviceApproverProvider);
    if (approver == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final p = await approver.lookup(input);
      if (mounted) {
        setState(() {
          _pending = p;
          _step = _Step.confirm;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = message(e);
          _scanGeneration++;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _approve() async {
    final approver = ref.read(deviceApproverProvider), p = _pending;
    if (approver == null || p == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await approver.approve(p);
      if (mounted) setState(() => _step = _Step.done);
    } catch (e) {
      if (mounted) setState(() => _error = message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _restart() => setState(() {
        _step = _Step.enter;
        _pending = null;
        _error = null;
        _code.clear();
        _scanGeneration++;
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go('/devices')),
        title: const Text('Add a device'),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...switch (_step) {
                    _Step.enter => _enter(theme),
                    _Step.confirm => _confirm(theme),
                    _Step.done => _done(theme),
                  },
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, key: const Key('pair-error'), style: TextStyle(color: theme.colorScheme.error)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _enter(ThemeData theme) {
    final scanner = ref.watch(qrScannerProvider);
    return [
      Text(
        'On the new device, choose "Sign in with another device". '
        '${scanner == null ? 'Then type the code it shows.' : 'Then scan the code it shows, or type it.'}',
        style: theme.textTheme.bodyLarge,
      ),
      if (scanner != null) ...[
        const SizedBox(height: 16),
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            key: ValueKey('scanner-$_scanGeneration'),
            height: 280,
            child: _busy ? const Center(child: CircularProgressIndicator()) : scanner(context, _lookup),
          ),
        ),
      ],
      const SizedBox(height: 16),
      TextField(
        key: const Key('pair-code-field'),
        controller: _code,
        enabled: !_busy,
        autocorrect: false,
        textCapitalization: TextCapitalization.characters,
        decoration: const InputDecoration(
          labelText: 'Code',
          hintText: 'XXXX-XXXX-XXXX-XXXX',
          border: OutlineInputBorder(),
        ),
        onSubmitted: _lookup,
      ),
      const SizedBox(height: 16),
      FilledButton(
        key: const Key('pair-find'),
        onPressed: _busy ? null : () => _lookup(_code.text),
        child: _busy
            ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Text('Find device'),
      ),
    ];
  }

  List<Widget> _confirm(ThemeData theme) {
    final p = _pending!;
    return [
      Icon(Icons.devices_rounded, size: 48, color: theme.colorScheme.primary),
      const SizedBox(height: 16),
      Text('Add "${p.deviceName}" (${platformLabel(p.platform)})?',
          textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
      const SizedBox(height: 8),
      const Text(
        'It will be signed in as you and can read all your chats, including their history. '
        'Only add a device you have in your hands.',
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 24),
      FilledButton(
        key: const Key('pair-approve'),
        onPressed: _busy ? null : _approve,
        child: _busy
            ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Text('Add device'),
      ),
      const SizedBox(height: 8),
      TextButton(onPressed: _busy ? null : _restart, child: const Text('Cancel')),
    ];
  }

  List<Widget> _done(ThemeData theme) => [
        Icon(Icons.check_circle_rounded, size: 48, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text('"${_pending!.deviceName}" was approved. Finish on the new device.',
            textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
        const SizedBox(height: 24),
        FilledButton(onPressed: () => context.go('/devices'), child: const Text('Done')),
      ];
}
