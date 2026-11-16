import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/providers.dart';
import '../../media/providers.dart';
import '../../session/session_controller.dart';
import '../../theme/tokens.dart';
import '../../widgets/brand_mark.dart';
import '../../widgets/common.dart';
import '../../widgets/person_avatar.dart';
import '../account_providers.dart';
import 'chat_list.dart';
import 'conversation_view.dart';
import 'quick_switcher.dart';

/// "Ctrl" or "⌘" in shortcut hints.
String get shortcutModifier =>
    {TargetPlatform.macOS, TargetPlatform.iOS}.contains(defaultTargetPlatform) ? '⌘' : 'Ctrl';

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
    final id = chatId;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () => showQuickSwitcher(context),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () => showQuickSwitcher(context),
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () => context.go('/new'),
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): () => context.go('/new'),
        if (id != null) const SingleActivator(LogicalKeyboardKey.escape): () => context.go('/'),
      },
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= twoPaneWidth;
          if (!wide) {
            return id == null ? const _ListPane(selectedId: null) : ConversationView(chatId: id);
          }
          return Row(children: [
            SizedBox(width: listWidth, child: _ListPane(selectedId: id)),
            const VerticalDivider(width: 1),
            Expanded(
              child: id == null
                  ? const _WelcomePane()
                  : ConversationView(key: ValueKey(id), chatId: id, showBack: false),
            ),
          ]);
        }),
      ),
    );
  }
}

class _ListPane extends ConsumerWidget {
  const _ListPane({required this.selectedId});

  final String? selectedId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final signedIn = session is SignedIn ? session.session : null;
    final admin = signedIn?.isAdmin ?? false;
    return Scaffold(
      appBar: AppBar(
        title: const Wordmark(),
        actions: [
          IconButton(
            tooltip: 'Find a chat ($shortcutModifier+K)',
            icon: const Icon(Icons.search_rounded),
            onPressed: () => showQuickSwitcher(context),
          ),
          IconButton(
            tooltip: 'New chat',
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: () => context.go('/new'),
          ),
          Padding(
            padding: const EdgeInsets.only(left: Space.xs, right: Space.md),
            child: IconButton(
              tooltip: 'Settings',
              padding: EdgeInsets.zero,
              icon: PersonAvatar(label: signedIn?.name ?? '?', colorKey: signedIn?.userId ?? '', radius: 17),
              onPressed: () => context.go('/settings'),
            ),
          ),
        ],
      ),
      body: Column(children: [
        // Admin setup: the recovery code is the last resort if every admin device is lost.
        if (admin && ref.watch(meProvider).value?.recoveryCodeSet == false)
          NoticeCard(
            key: const Key('admin-setup-banner'),
            tone: NoticeTone.highlight,
            icon: Icons.key_rounded,
            text: 'Save your admin recovery code, and consider making a second admin.',
            actions: [
              TextButton(
                onPressed: () => context.go('/family'),
                style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer),
                child: const Text('Set up'),
              ),
            ],
          ),
        Expanded(child: ChatList(selectedId: selectedId)),
      ]),
    );
  }
}

/// The right pane before a chat is picked.
class _WelcomePane extends StatelessWidget {
  const _WelcomePane();

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: FamTokens.of(context).chatBackdrop,
        child: EmptyState(
          art: const BrandMark(size: 64),
          title: 'Pick a chat',
          body: 'Or start a new one. Press $shortcutModifier+K to jump to any chat.',
          action: OutlinedButton.icon(
            onPressed: () => context.go('/new'),
            icon: const Icon(Icons.add_comment_outlined),
            label: const Text('New chat'),
          ),
        ),
      );
}
