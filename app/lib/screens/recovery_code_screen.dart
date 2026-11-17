// Admin: make the printed admin recovery code. It is shown once and never stored: only the
// public half of the key derived from it goes to the server (docs/protocol.md "Admin recovery code").
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../admin/admin_providers.dart';
import '../crypto/reset.dart';
import '../session/session_controller.dart';
import 'account_providers.dart';
import 'sign_out.dart';

const _mono = TextStyle(fontFamily: 'monospace', fontFamilyFallback: ['Courier New', 'Courier'], letterSpacing: 1.5);

class RecoveryCodeScreen extends ConsumerStatefulWidget {
  const RecoveryCodeScreen({super.key});

  @override
  ConsumerState<RecoveryCodeScreen> createState() => _RecoveryCodeScreenState();
}

class _RecoveryCodeScreenState extends ConsumerState<RecoveryCodeScreen> {
  RecoveryCode? _code;
  bool _busy = false;
  String? _error;

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final code = await ref.read(adminServiceProvider)!.createRecoveryCode();
      if (mounted) setState(() => _code = code);
    } catch (e) {
      if (mounted) setState(() => _error = apiErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _done() {
    ref.invalidate(meProvider);
    context.go('/settings/family');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final code = _code;
    final had = ref.watch(meProvider).value?.recoveryCodeSet ?? false;
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: code == null ? () => context.go('/settings/family') : _done),
        title: const Text('Admin recovery code'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (code == null) ...[
                Text(
                  'If you lose every device and no other admin can reset your account, this code gets you '
                  'back in. FamChat shows it once and doesn’t keep it, and the server can’t use it.',
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 12),
                const Text('Print it or write it down, and keep it somewhere safe at home, like with important papers.'),
                if (had) ...[
                  const SizedBox(height: 12),
                  Text('Making a new code replaces your current one.', style: TextStyle(color: theme.colorScheme.error)),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  key: const Key('create-recovery-code'),
                  onPressed: _busy ? null : _create,
                  child: _busy
                      ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Make my recovery code'),
                ),
              ] else ...[
                Text('Your admin recovery code', style: theme.textTheme.titleLarge),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: SelectableText(
                      code.display,
                      key: const Key('recovery-code'),
                      textAlign: TextAlign.center,
                      style: _mono.copyWith(fontSize: 22),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'This is the only time you’ll see it. Anyone who has it can take over your admin account, '
                  'so don’t keep it in your email or photos.',
                ),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('copy-recovery-code'),
                      icon: const Icon(Icons.copy),
                      label: const Text('Copy'),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: code.display));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Code copied')));
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('print-recovery-code'),
                      icon: const Icon(Icons.print_outlined),
                      label: const Text('Print view'),
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                        fullscreenDialog: true,
                        builder: (_) => RecoveryCodePrintView(code: code, name: _name()),
                      )),
                    ),
                  ),
                ]),
                const SizedBox(height: 16),
                FilledButton(key: const Key('recovery-code-saved'), onPressed: _done, child: const Text('I saved it')),
              ],
            ]),
          ),
        ),
      ),
    );
  }

  String? _name() {
    final s = ref.read(sessionProvider);
    return s is SignedIn ? s.session.name : null;
  }
}

/// A plain black-on-white page to print (the browser's or system's print, or a screenshot).
class RecoveryCodePrintView extends StatelessWidget {
  const RecoveryCodePrintView({super.key, required this.code, this.name});

  final RecoveryCode code;
  final String? name;

  @override
  Widget build(BuildContext context) {
    const ink = TextStyle(color: Colors.black);
    final date = MaterialLocalizations.of(context).formatMediumDate(DateTime.now());
    return Theme(
      data: ThemeData.light(),
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          title: const Text('Print this page'),
        ),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: DefaultTextStyle(
                style: ink.copyWith(fontSize: 16, height: 1.4),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('FamChat admin recovery code', style: ink.copyWith(fontSize: 26, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text('${name ?? 'Admin'} · made $date'),
                  const SizedBox(height: 24),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(border: Border.all(color: Colors.black, width: 2)),
                    child: Text(
                      code.display,
                      key: const Key('printed-recovery-code'),
                      textAlign: TextAlign.center,
                      style: _mono.copyWith(fontSize: 26, color: Colors.black, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text('If you lose every device and no other admin can help:'),
                  const SizedBox(height: 8),
                  const Text('1. Open FamChat on any device (famchat.dev on the web).'),
                  const Text('2. Choose "Recover admin account" and type this code.'),
                  const Text('3. Your old devices are signed out; your chats come back from the family.'),
                  const SizedBox(height: 16),
                  const Text('The code works once. Keep this paper somewhere safe; anyone holding it can take over the admin account.'),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
