// Settings → Starred messages: my starred messages across every chat, newest star first.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../chat/db/chat_db.dart';
import '../chat/message_changes.dart';
import '../chat/providers.dart';
import 'chats/chat_media_screen.dart' show StarredList;

class StarredScreen extends ConsumerWidget {
  const StarredScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final starred = ref.watch(starredMessagesProvider(null)).value ?? const <MessageRow>[];
    // Deleted messages drop out: their deletes are in each chat's changes.
    final byChat = <String, List<MessageRow>>{};
    for (final m in starred) {
      byChat.putIfAbsent(m.chatId, () => []);
    }
    final deleted = <String>{
      for (final chatId in byChat.keys)
        for (final m in ref.watch(messagesProvider(chatId)).value ?? const <MessageRow>[])
          if (m.kind == 'delete' && m.targetId != null) m.targetId!,
    };
    final shown = [for (final m in starred) if (!deleted.contains(m.id)) m];
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go('/settings')),
        title: const Text('Starred messages'),
      ),
      body: StarredList(messages: shown, changes: messageChanges(shown)),
    );
  }
}
