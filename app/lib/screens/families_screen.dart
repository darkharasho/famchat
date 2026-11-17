// Settings → Families: the families I'm in or have asked to start, and starting a new one (the
// operator approves it).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../api/models.dart';
import '../chat/providers.dart';
import '../session/session_controller.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import 'sign_out.dart';

class FamiliesScreen extends ConsumerWidget {
  const FamiliesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final families = ref.watch(familiesProvider);
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go('/settings')),
        title: const Text('Families'),
      ),
      // A refresh (or one that failed) keeps showing what was there.
      body: families.hasValue
          ? ListView(
              padding: EdgeInsets.only(top: Space.sm, bottom: Space.xxl + MediaQuery.paddingOf(context).bottom),
              children: [
                ContentWidth(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (families.value!.isNotEmpty)
                      SettingsGroup(children: [for (final f in families.value!) _FamilyTile(family: f)]),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Space.lg),
                      child: FilledButton.icon(
                        key: const Key('start-family'),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Start a family'),
                        onPressed: () => _start(context, ref),
                      ),
                    ),
                  ]),
                ),
              ],
            )
          : families.hasError
              ? Center(
                  child: TextButton(onPressed: () => ref.invalidate(familiesProvider), child: const Text('Try again')),
                )
              : const Center(child: CircularProgressIndicator()),
    );
  }
}

class _FamilyTile extends ConsumerWidget {
  const _FamilyTile({required this.family});
  final Family family;

  static String _people(int n) => '$n ${n == 1 ? 'person' : 'people'}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = family;
    return ListTile(
      key: Key('family-tile-${f.id}'),
      leading: const TileIcon(Icons.diversity_3_rounded),
      title: Text(f.name),
      subtitle: Text(switch (f.status) {
        'pending' => 'Waiting for approval',
        'declined' => 'Declined',
        _ => '${f.owner ? 'Owner' : f.admin ? 'Admin' : 'Member'} · ${_people(f.memberCount)}',
      }),
      trailing: switch (f.status) {
        'declined' => TextButton(
            key: Key('dismiss-family-${f.id}'),
            onPressed: () => _dismiss(context, ref, f),
            child: const Text('Dismiss'),
          ),
        _ => const Icon(Icons.chevron_right_rounded),
      },
      onTap: () => context.go('/settings/families/${f.id}'),
    );
  }
}

Future<void> _dismiss(BuildContext context, WidgetRef ref, Family f) async {
  final me = ref.read(myUserIdProvider);
  final messenger = ScaffoldMessenger.of(context);
  if (me == null) return;
  try {
    await ref.read(apiClientProvider).leaveOrRemove(f.id, me);
    await ref.read(familiesProvider.notifier).refresh();
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(apiErrorMessage(e))));
  }
}

Future<void> _start(BuildContext context, WidgetRef ref) async {
  final name = await showDialog<String>(context: context, builder: (context) => const _StartDialog());
  if (name == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await ref.read(apiClientProvider).createFamily(name);
    await ref.read(familiesProvider.notifier).refresh();
    messenger.showSnackBar(const SnackBar(content: Text("Request sent. You'll be told when it's approved.")));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(apiErrorMessage(e))));
  }
}

class _StartDialog extends StatefulWidget {
  const _StartDialog();

  @override
  State<_StartDialog> createState() => _StartDialogState();
}

class _StartDialogState extends State<_StartDialog> {
  static const maxLength = 40;
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String get _value => _text.text.trim();

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Start a family'),
        content: TextField(
          key: const Key('family-name-field'),
          controller: _text,
          autofocus: true,
          maxLength: maxLength,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Family name',
            helperText: 'The operator approves new families',
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) {
            if (_value.isNotEmpty) Navigator.pop(context, _value);
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            key: const Key('start-family-send'),
            onPressed: _value.isEmpty ? null : () => Navigator.pop(context, _value),
            child: const Text('Ask to start it'),
          ),
        ],
      );
}
