import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../session/session_controller.dart';
import 'account_providers.dart';
import 'sign_out.dart';

/// Signed-in home. Chats arrive in plan 5; for now it greets the user.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(meProvider); // refreshes the stored name and admin flag
    final session = ref.watch(sessionProvider);
    if (session is! SignedIn) return const Scaffold();
    final name = session.session.name;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('FamChat'),
        actions: [
          if (session.session.isAdmin)
            IconButton(
              tooltip: 'Invite someone',
              icon: const Icon(Icons.person_add_alt_1_outlined),
              onPressed: () => context.go('/invite'),
            ),
          IconButton(
            tooltip: 'Devices',
            icon: const Icon(Icons.devices_outlined),
            onPressed: () => context.go('/devices'),
          ),
          PopupMenuButton<String>(
            onSelected: (v) => switch (v) {
              'spikes' => context.go('/spikes'),
              _ => confirmSignOut(context, ref),
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'spikes', child: Text('Platform spikes')),
              PopupMenuItem(value: 'signout', child: Text('Sign out')),
            ],
          ),
        ],
      ),
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(name == null ? 'Hi' : 'Hi, $name', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 12),
          Icon(Icons.forum_outlined, size: 48, color: theme.colorScheme.primary),
          const SizedBox(height: 12),
          Text('Chats coming soon', style: theme.textTheme.bodyLarge),
        ]),
      ),
    );
  }
}
