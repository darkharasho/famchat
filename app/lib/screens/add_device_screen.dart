import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../pairing/approver.dart';
import '../pairing/new_device_pairing.dart' show NewDevicePairing;
import '../pairing/pairing_providers.dart';
import '../session/session_controller.dart' show clockProvider;
import '../widgets/pair_qr_view.dart';
import 'devices_screen.dart' show platformLabel;
import 'sign_out.dart';

/// "Add a device": scan (phones) or type the code a new device shows, or show a code for the new
/// device to scan (the default without a camera); check the new device and approve it.
class AddDeviceScreen extends ConsumerStatefulWidget {
  const AddDeviceScreen({super.key});

  @override
  ConsumerState<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

enum _Step { enter, confirm, done }

/// Enter (scan or type) the new device's code, or show this device's code to the new device.
enum _Mode { enter, show }

enum _OfferState { none, creating, showing, expired, failed }

class _AddDeviceScreenState extends ConsumerState<AddDeviceScreen> {
  final _code = TextEditingController();
  _Step _step = _Step.enter;
  late _Mode _mode;
  PendingApproval? _pending;
  bool _busy = false;
  String? _error;

  /// A rescan needs a fresh scanner (it reports once).
  int _scanGeneration = 0;

  // "Show a code": the open offer, who opened it (to withdraw it after this widget is gone), and
  // a generation so answers for a replaced offer are ignored.
  _OfferState _offerState = _OfferState.none;
  DeviceOffer? _offer;
  DeviceApprover? _offerApprover;
  int _offerGeneration = 0;
  Timer? _poll, _tick;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _mode = ref.read(qrScannerProvider) == null ? _Mode.show : _Mode.enter;
    if (_mode == _Mode.show) scheduleMicrotask(_startOffer);
  }

  @override
  void dispose() {
    _stopOffer();
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
        PairingException(kind: PairingError.expired) => 'This code expired.',
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

  // --- "Show a code" ---

  /// Opens a new offer (withdrawing any current one) and polls until a new device takes it.
  Future<void> _startOffer() async {
    final approver = ref.read(deviceApproverProvider);
    if (approver == null || !mounted) return;
    _stopOffer();
    final generation = _offerGeneration;
    setState(() {
      _offerState = _OfferState.creating;
      _error = null;
    });
    try {
      final offer = await approver.createOffer();
      if (!mounted || generation != _offerGeneration) {
        unawaited(approver.cancelOffer(offer));
        return;
      }
      _offer = offer;
      _offerApprover = approver;
      _poll = Timer.periodic(ref.read(pairPollEveryProvider), (_) => _checkOffer(generation));
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
      setState(() => _offerState = _OfferState.showing);
    } catch (e) {
      if (mounted && generation == _offerGeneration) {
        setState(() {
          _offerState = _OfferState.failed;
          _error = message(e);
        });
      }
    }
  }

  Future<void> _checkOffer(int generation) async {
    final offer = _offer, approver = _offerApprover;
    if (_checking || offer == null || approver == null || generation != _offerGeneration) return;
    _checking = true;
    try {
      final p = await approver.checkOffer(offer);
      if (!mounted || generation != _offerGeneration || p == null) return;
      _stopTimers();
      setState(() {
        _pending = p;
        _step = _Step.confirm;
      });
    } on PairingException catch (e) {
      if (!mounted || generation != _offerGeneration) return;
      // A mismatch means someone else's keys took the offer: withdraw it, which ends their session.
      _stopOffer();
      setState(() {
        _offerState = e.kind == PairingError.expired ? _OfferState.expired : _OfferState.failed;
        _error = e.kind == PairingError.expired ? null : message(e);
      });
    } catch (_) {
      // Server or network trouble: keep trying until well past expiry.
      final pastExpiry = ref.read(clockProvider)().isAfter(offer.expiresAt.add(NewDevicePairing.unreachableGrace));
      if (pastExpiry && mounted && generation == _offerGeneration) {
        _stopOffer();
        setState(() => _offerState = _OfferState.expired);
      }
    } finally {
      _checking = false;
    }
  }

  void _stopTimers() {
    _poll?.cancel();
    _tick?.cancel();
    _poll = _tick = null;
  }

  /// Stops polling and withdraws the open offer, if any (also ending a new device's session that
  /// took it and wasn't approved).
  void _stopOffer() {
    _stopTimers();
    _offerGeneration++;
    final offer = _offer, approver = _offerApprover;
    _offer = _offerApprover = null;
    if (offer != null && approver != null) unawaited(approver.cancelOffer(offer));
  }

  void _setMode(_Mode m) {
    if (m == _mode) return;
    setState(() {
      _mode = m;
      _error = null;
      _scanGeneration++;
    });
    if (m == _Mode.show) {
      unawaited(_startOffer());
    } else {
      _stopOffer();
      setState(() => _offerState = _OfferState.none);
    }
  }

  // --- confirm ---

  Future<void> _approve() async {
    final approver = ref.read(deviceApproverProvider), p = _pending;
    if (approver == null || p == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await approver.approve(p);
      _offer = _offerApprover = null; // used up; nothing to withdraw
      if (mounted) setState(() => _step = _Step.done);
    } catch (e) {
      if (mounted) setState(() => _error = message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _restart() {
    _stopOffer();
    setState(() {
      _step = _Step.enter;
      _pending = null;
      _error = null;
      _offerState = _OfferState.none;
      _code.clear();
      _scanGeneration++;
    });
    if (_mode == _Mode.show) unawaited(_startOffer());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go('/settings/devices')),
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
                    _Step.enter => [
                        _modePicker(),
                        const SizedBox(height: 20),
                        ...switch (_mode) {
                          _Mode.enter => _enter(theme),
                          _Mode.show => _show(theme),
                        },
                      ],
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

  Widget _modePicker() {
    final scanner = ref.watch(qrScannerProvider);
    return SegmentedButton<_Mode>(
      showSelectedIcon: false,
      segments: [
        ButtonSegment(
          value: _Mode.enter,
          icon: Icon(scanner == null ? Icons.keyboard_rounded : Icons.qr_code_scanner_rounded),
          label: Text(scanner == null ? 'Type a code' : 'Scan a code', key: const Key('mode-enter')),
        ),
        const ButtonSegment(
          value: _Mode.show,
          icon: Icon(Icons.qr_code_2_rounded),
          label: Text('Show a code', key: Key('mode-show')),
        ),
      ],
      selected: {_mode},
      onSelectionChanged: _busy ? null : (s) => _setMode(s.single),
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
          borderRadius: BorderRadius.circular(20),
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
        style: const TextStyle(fontSize: 18, letterSpacing: 1.5, fontFeatures: [FontFeature.tabularFigures()]),
        decoration: const InputDecoration(
          labelText: 'Code',
          hintText: 'XXXX-XXXX-XXXX-XXXX',
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

  List<Widget> _show(ThemeData theme) {
    final offer = _offer;
    return switch (_offerState) {
      _OfferState.none || _OfferState.creating => [const Center(child: CircularProgressIndicator())],
      _OfferState.showing when offer != null => [
          Text(
            'On the new device, choose "Sign in with another device", then "Scan a code from your other device". '
            'Scan this code with it, or type it in.',
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 24),
          PairQrView(
            data: offer.qr,
            display: offer.code.display,
            qrKey: const Key('offer-qr'),
            codeKey: const Key('offer-code'),
          ),
          const SizedBox(height: 8),
          Text(
            'Expires in ${timeLeft(offer.expiresAt, ref.read(clockProvider)())}',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 12),
              Flexible(child: Text('Waiting for the new device…')),
            ],
          ),
        ],
      _OfferState.showing || _OfferState.expired || _OfferState.failed => [
          if (_offerState != _OfferState.failed)
            Text('This code expired.', textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
          const SizedBox(height: 16),
          FilledButton(key: const Key('offer-restart'), onPressed: _startOffer, child: const Text('Get a new code')),
        ],
    };
  }

  List<Widget> _confirm(ThemeData theme) {
    final p = _pending!;
    return [
      Center(child: _Badge(icon: Icons.devices_rounded)),
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
        Center(child: _Badge(icon: Icons.check_rounded)),
        const SizedBox(height: 16),
        Text('"${_pending!.deviceName}" was approved. Finish on the new device.',
            textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
        const SizedBox(height: 24),
        FilledButton(onPressed: () => context.go('/settings/devices'), child: const Text('Done')),
      ];
}

/// A round amber badge with an icon, heading a step.
class _Badge extends StatelessWidget {
  const _Badge({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      width: 72,
      height: 72,
      decoration: BoxDecoration(color: s.secondaryContainer, shape: BoxShape.circle),
      child: Icon(icon, size: 36, color: s.onSecondaryContainer),
    );
  }
}
