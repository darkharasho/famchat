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
    // Each chat's own changes: edits show, and only deletes the chat honours hide a message.
    final changes = <String, MessageChanges>{
      for (final chatId in {for (final m in starred) m.chatId})
        chatId: messageChanges(ref.watch(messagesProvider(chatId)).value ?? const <MessageRow>[]),
    };
    final shown = [for (final m in starred) if (!changes[m.chatId]!.isDeleted(m.id)) m];
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go('/settings')),
        title: const Text('Starred messages'),
      ),
      body: StarredList(messages: shown, changesOf: (m) => changes[m.chatId]!),
    );
  }
}
