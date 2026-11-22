// "Send to…": pick the chat a share from another app goes to.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../chat/providers.dart';
import '../push/providers.dart' show rootMessengerKeyProvider;
import '../media/providers.dart';
import '../media/send_media.dart';
import '../share/share.dart';
import '../theme/tokens.dart';
import '../widgets/person_avatar.dart';

class ShareScreen extends ConsumerStatefulWidget {
  const ShareScreen({super.key});

  @override
  ConsumerState<ShareScreen> createState() => _ShareScreenState();
}

class _ShareScreenState extends ConsumerState<ShareScreen> {
  /// A chat was picked: further taps (a double tap) do nothing.
  bool _sending = false;

  /// Forgets the share. Call after navigating away: with no share, this screen goes home.
  static void _finish(PendingShare pending, ShareSource source) {
    pending.set(null);
    unawaited(source.done());
  }

  Future<void> _sendTo(IncomingShare share, String chatId) async {
    if (_sending) return;
    _sending = true;
    // Read everything now: this screen is gone once the chat opens.
    final media = ref.read(mediaServiceProvider);
    final videos = ref.read(videoProcessorProvider);
    final db = ref.read(chatDbProvider);
    final messenger = ref.read(rootMessengerKeyProvider).currentState;
    final pending = ref.read(pendingShareProvider.notifier), source = ref.read(shareSourceProvider);
    // Text waits in the composer, to read over (or edit) before sending.
    // Added to what's already typed there, never replacing it.
    if (share.text case final text? when text.trim().isNotEmpty) {
      final draft = await db.draftOf(chatId);
      await db.setDraft(chatId, draft == null || draft.trim().isEmpty ? text : '$draft\n$text');
    }
    if (mounted) context.go('/chats/$chatId');
    _finish(pending, source);
    if (media == null || share.media.isEmpty) return;
    final report = await sendMedia(media, videos, chatId, share.media);
    if (report.problem case final p?) messenger?.showSnackBar(SnackBar(content: Text(p)));
  }

  @override
  Widget build(BuildContext context) {
    final share = ref.watch(pendingShareProvider);
    if (share == null) {
      // Opened with nothing to send (a stale link): home. Not while leaving for the chat it went to.
      final route = ModalRoute.of(context);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted && (route?.isCurrent ?? false)) context.go('/');
      });
      return const Scaffold();
    }
    final items = ref.watch(chatListProvider).value ?? const [];
    final users = ref.watch(usersProvider).value ?? const {};
    final me = ref.watch(myUserIdProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Cancel',
          icon: const Icon(Icons.close_rounded),
          onPressed: () {
            final pending = ref.read(pendingShareProvider.notifier), source = ref.read(shareSourceProvider);
            context.go('/');
            _finish(pending, source);
          },
        ),
        title: const Text('Send to…'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.sm),
          child: Row(children: [
            Icon(Icons.ios_share_rounded, color: theme.colorScheme.tertiary),
            const SizedBox(width: Space.md),
            Expanded(child: Text(shareSummary(share), style: theme.textTheme.titleSmall)),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: items.isEmpty
              ? const Center(child: Text('No chats yet.'))
              : ListView(children: [
                  for (final i in items)
                    Builder(builder: (context) {
                      final title = chatTitle(i.chat, i.members, users, me);
                      final group = i.chat.kind == 'group';
                      final other = otherMember(i.chat, i.members, me);
                      return ListTile(
                        key: Key('share-to-${i.chat.id}'),
                        leading: PersonAvatar(
                          label: title,
                          colorKey: group ? i.chat.id : (other ?? i.chat.id),
                          userId: group ? null : other,
                          group: group,
                          chatId: i.chat.id,
                          chatPhotoKey: i.chat.avatarKey,
                        ),
                        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => _sendTo(share, i.chat.id),
                      );
                    }),
                ]),
        ),
      ]),
    );
  }
}
