import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/providers.dart';
import '../../media/providers.dart';
import '../../push/providers.dart';
import '../../session/session_controller.dart';
import '../account_providers.dart';
import '../sign_out.dart';
import 'chat_list.dart';
import 'conversation_view.dart';

/// Signed-in home. Phones: the chat list, or one conversation full screen. From [twoPaneWidth]:
/// the list and the open conversation side by side.
class ChatsShell extends ConsumerWidget {
  const ChatsShell({super.key, this.chatId});

  final String? chatId;

  static const twoPaneWidth = 720.0;
  static const listWidth = 360.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(meProvider); // keeps the stored name and admin flag current
    ref.watch(chatSyncProvider); // starts the chat engine
    ref.watch(mediaServiceProvider); // and the media pipeline (its outbox gate)
    ref.watch(notificationsProvider); // push registration, desktop notifications
    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= twoPaneWidth;
      if (!wide) {
        return chatId == null ? _ListPane(selectedId: null) : ConversationView(chatId: chatId!);
      }
      return Row(children: [
        SizedBox(width: listWidth, child: _ListPane(selectedId: chatId)),
        const VerticalDivider(width: 1),
        Expanded(
          child: chatId == null
              ? const Scaffold(body: Center(child: Text('Select a chat')))
              : ConversationView(key: ValueKey(chatId), chatId: chatId!, showBack: false),
        ),
      ]);
    });
  }
}

class _ListPane extends ConsumerWidget {
  const _ListPane({required this.selectedId});

  final String? selectedId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final admin = session is SignedIn && session.session.isAdmin;
    return Scaffold(
      appBar: AppBar(
        title: const Text('FamChat'),
        actions: [
          IconButton(tooltip: 'New chat', icon: const Icon(Icons.edit_outlined), onPressed: () => context.go('/new')),
          if (admin)
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
              'storage' => context.go('/storage'),
              'family' => context.go('/family'),
              _ => confirmSignOut(context, ref),
            },
            itemBuilder: (context) => [
              if (admin) const PopupMenuItem(value: 'family', child: Text('Family')),
              if (admin) const PopupMenuItem(value: 'storage', child: Text('Storage')),
              const PopupMenuItem(value: 'spikes', child: Text('Platform spikes')),
              const PopupMenuItem(value: 'signout', child: Text('Sign out')),
            ],
          ),
        ],
      ),
      body: Column(children: [
        if (ref.watch(notifyOfferProvider))
          MaterialBanner(
            leading: const Icon(Icons.notifications_outlined),
            content: const Text('Get notified about new messages while FamChat is in the background.'),
            actions: [
              TextButton(onPressed: () => ref.read(notifyOfferProvider.notifier).dismiss(), child: const Text('Not now')),
              FilledButton(onPressed: () => ref.read(notifyOfferProvider.notifier).enable(), child: const Text('Turn on')),
            ],
          ),
        // Admin setup: the recovery code is the last resort if every admin device is lost.
        if (admin && ref.watch(meProvider).value?.recoveryCodeSet == false)
          MaterialBanner(
            key: const Key('admin-setup-banner'),
            leading: const Icon(Icons.key_outlined),
            content: const Text('Save your admin recovery code, and consider making a second admin.'),
            actions: [TextButton(onPressed: () => context.go('/family'), child: const Text('Set up'))],
          ),
        Expanded(child: ChatList(selectedId: selectedId)),
      ]),
    );
  }
}
