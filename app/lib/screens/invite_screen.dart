import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../api/models.dart';
import '../session/session_controller.dart';
import '../theme/tokens.dart';
import 'sign_out.dart';

/// Admin of [familyId] only: create a one-time invite link for a new member of it.
class InviteScreen extends ConsumerStatefulWidget {
  const InviteScreen({super.key, required this.familyId});

  final int familyId;

  @override
  ConsumerState<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends ConsumerState<InviteScreen> {
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;
  (String, Invite)? _created;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty || name.runes.length > 40) {
      setState(() => _error = 'Enter their name (up to 40 characters).');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final invite = await ref.read(apiClientProvider).createFamilyInvite(widget.familyId, name);
      if (mounted) setState(() => _created = (name, invite));
    } catch (e) {
      if (mounted) setState(() => _error = apiErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final created = _created;
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go('/settings/families/${widget.familyId}')),
        title: const Text('Invite someone'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: created == null ? _form(theme) : _result(theme, created.$1, created.$2),
          ),
        ),
      ),
    );
  }

  Widget _form(ThemeData theme) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Who is joining?', style: theme.textTheme.headlineSmall),
        const SizedBox(height: Space.sm),
        Text(
          'They get a one-time link that signs them in on their first device.',
          style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: Space.xl),
        TextField(
          key: const Key('invite-name-field'),
          controller: _name,
          enabled: !_busy,
          maxLength: 40,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Their name'),
          onSubmitted: (_) => _create(),
        ),
        if (_error != null) Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        const SizedBox(height: 16),
        FilledButton(
          key: const Key('create-invite-button'),
          onPressed: _busy ? null : _create,
          child: _busy
              ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Create invite link'),
        ),
      ]);

  Widget _result(ThemeData theme, String name, Invite invite) {
    final expires = MaterialLocalizations.of(context).formatMediumDate(invite.expiresAt);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Invite for $name', style: theme.textTheme.titleLarge),
      const SizedBox(height: 12),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: SelectableText(invite.inviteUrl, style: theme.textTheme.bodyLarge),
        ),
      ),
      const SizedBox(height: 8),
      Text('Only share this with $name. It works once and expires on $expires.'),
      const SizedBox(height: 16),
      FilledButton.icon(
        key: const Key('copy-invite-button'),
        icon: const Icon(Icons.copy_rounded),
        label: const Text('Copy link'),
        onPressed: () => _copy(invite.inviteUrl),
      ),
      const SizedBox(height: 8),
      TextButton(
        onPressed: () => setState(() {
          _created = null;
          _name.clear();
        }),
        child: const Text('Invite someone else'),
      ),
    ]);
  }
}
