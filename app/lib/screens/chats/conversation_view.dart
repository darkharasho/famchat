import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/providers.dart';

/// One chat: header, messages and the composer.
class ConversationView extends ConsumerWidget {
  const ConversationView({super.key, required this.chatId, this.showBack = true});

  final String chatId;
  final bool showBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chat = ref.watch(chatProvider(chatId)).value;
    final members = ref.watch(membersProvider(chatId)).value ?? const [];
    final users = ref.watch(usersProvider).value ?? const {};
    final me = ref.watch(myUserIdProvider);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: showBack,
        title: Text(chat == null ? '' : chatTitle(chat, members, users, me)),
      ),
    );
  }
}
