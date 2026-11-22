import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../chat/providers.dart';
import '../../media/providers.dart';
import '../../push/providers.dart';
import '../../session/session_controller.dart';
import '../../settings/list_width.dart';
import '../../theme/tokens.dart';
import '../../widgets/brand_mark.dart';
import '../../widgets/common.dart';
import '../../widgets/person_avatar.dart';
import '../account_providers.dart';
import 'chat_list.dart';
import 'conversation_view.dart';
import 'pane_divider.dart';
import 'quick_switcher.dart';

/// "Ctrl" or "⌘" in shortcut hints.
String get shortcutModifier =>
    {TargetPlatform.macOS, TargetPlatform.iOS}.contains(defaultTargetPlatform) ? '⌘' : 'Ctrl';

/// Signed-in home. Phones: the chat list, or one conversation full screen. From [twoPaneWidth]:
/// the list and the open conversation side by side, split by a divider that resizes the list.
class ChatsShell extends ConsumerWidget {
  const ChatsShell({super.key, this.chatId, this.jumpTo});

  final String? chatId;

  /// A message to scroll to once the chat opens (from search).
  final String? jumpTo;

  static const twoPaneWidth = 720.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(meProvider); // keeps the stored name and admin flag current
    ref.watch(chatSyncProvider); // starts the chat engine
    ref.watch(mediaServiceProvider); // and the media pipeline (its outbox gate)
    ref.watch(notificationsProvider); // push registration, desktop notifications
    ref.listen(familyApprovalsProvider, (_, next) {
      if (next case AsyncData(:final value)) {
        ref.read(rootMessengerKeyProvider).currentState?.showSnackBar(SnackBar(content: Text('${value.name} was approved')));
      }
    });
    final id = chatId;
    // Cmd on Apple platforms (where Ctrl+K and Ctrl+N edit text), Ctrl elsewhere.
    final apple = {TargetPlatform.macOS, TargetPlatform.iOS}.contains(defaultTargetPlatform);
    return CallbackShortcuts(
      bindings: {
        SingleActivator(LogicalKeyboardKey.keyK, control: !apple, meta: apple): () => showQuickSwitcher(context),
        SingleActivator(LogicalKeyboardKey.keyN, control: !apple, meta: apple): () => context.go('/new'),
        SingleActivator(LogicalKeyboardKey.keyF, control: !apple, meta: apple, shift: true): () => context.go('/search'),
        if (id != null)
          SingleActivator(LogicalKeyboardKey.keyF, control: !apple, meta: apple): () => context.go('/search?chat=$id'),
        if (id != null) const SingleActivator(LogicalKeyboardKey.escape): () => context.go('/'),
      },
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= twoPaneWidth;
          if (!wide) {
            return id == null
                ? const _ListPane(selectedId: null)
                : ConversationView(key: ValueKey(id), chatId: id, jumpTo: jumpTo);
          }
          final listWidth = clampListWidth(ref.watch(listWidthProvider), c.maxWidth);
          return Stack(fit: StackFit.expand, children: [
            Row(children: [
              SizedBox(width: listWidth, child: _ListPane(selectedId: id)),
              const VerticalDivider(width: 1),
              Expanded(
                child: id == null
                    ? const _WelcomePane()
                    : ConversationView(key: ValueKey(id), chatId: id, showBack: false, jumpTo: jumpTo),
              ),
            ]),
            // The grab strip straddles the 1px line rather than taking room in the row.
            Positioned(
              left: listWidth + 0.5 - PaneDivider.grabWidth / 2,
              top: 0,
              bottom: 0,
              child: PaneDivider(shownWidth: listWidth),
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
        // An open chat is a route above this one, which would give the list a back arrow.
        automaticallyImplyLeading: false,
        title: const Wordmark(),
        actions: [
          IconButton(
            tooltip: 'Search people and messages ($shortcutModifier+Shift+F)',
            icon: const Icon(Icons.search_rounded),
            onPressed: () => context.go('/search'),
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
              icon: PersonAvatar(label: signedIn?.name ?? '?', colorKey: signedIn?.userId ?? '', userId: signedIn?.userId, radius: 17),
              onPressed: () => context.go('/settings'),
            ),
          ),
        ],
      ),
      body: Column(children: [
        if (ref.watch(notifyOfferProvider))
          NoticeCard(
            key: const Key('notify-offer'),
            icon: Icons.notifications_outlined,
            text: 'Get notified about new messages while FamChat is in the background.',
            actions: [
              TextButton(onPressed: () => ref.read(notifyOfferProvider.notifier).dismiss(), child: const Text('Not now')),
              TextButton(onPressed: () => ref.read(notifyOfferProvider.notifier).enable(), child: const Text('Turn on')),
            ],
          ),
        if (ref.watch(notificationsOffProvider))
          NoticeCard(
            key: const Key('notifications-off'),
            icon: Icons.notifications_off_outlined,
            text: "Notifications are off, so you won't hear about new messages.",
            actions: [
              TextButton(onPressed: () => ref.read(notificationsOffProvider.notifier).dismiss(), child: const Text('Not now')),
              TextButton(onPressed: () => _turnOnNotifications(context, ref), child: const Text('Turn on')),
            ],
          ),
        // Admin setup: the recovery code is the last resort if every admin device is lost.
        if (admin && ref.watch(meProvider).value?.recoveryCodeSet == false)
          NoticeCard(
            key: const Key('admin-setup-banner'),
            tone: NoticeTone.highlight,
            icon: Icons.key_rounded,
            text: 'Save your admin recovery code, and consider making a second admin.',
            actions: [
              TextButton(
                onPressed: () => context.go('/settings/families/1'),
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
/// Asks for notification permission; when the phone won't ask again, says where to turn them on
/// (on iPhone, opening FamChat's page in Settings).
Future<void> _turnOnNotifications(BuildContext context, WidgetRef ref) async {
  if (await ref.read(notificationsOffProvider.notifier).turnOn() || !context.mounted) return;
  final ios = defaultTargetPlatform == TargetPlatform.iOS;
  final open = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('notifications-blocked'),
      title: const Text('Turn on notifications'),
      content: Text(ios
          ? 'Notifications are turned off for FamChat. In Settings, tap Notifications and turn on Allow Notifications.'
          : "Notifications are turned off for FamChat. Open your phone's Settings, then Apps, FamChat, "
              'Notifications, and allow them. If your phone puts apps to sleep to save battery, '
              'set FamChat to Unrestricted there too.'),
      actions: [
        if (ios) TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, ios), child: Text(ios ? 'Open Settings' : 'OK')),
      ],
    ),
  );
  if (open == true) await launchUrl(Uri.parse('app-settings:'));
}

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
