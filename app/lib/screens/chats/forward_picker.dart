// Where to forward a message: the other chats, newest activity first.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/person_avatar.dart';

/// The chat picked (id, title), or null when dismissed.
Future<({String id, String title})?> showForwardPicker(BuildContext context, {required String fromChatId}) =>
    showModalBottomSheet<({String id, String title})>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _ForwardSheet(fromChatId: fromChatId),
    );

class _ForwardSheet extends ConsumerWidget {
  const _ForwardSheet({required this.fromChatId});

  final String fromChatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = (ref.watch(chatListProvider).value ?? const []).where((i) => i.chat.id != fromChatId).toList();
    final users = ref.watch(usersProvider).value ?? const {};
    final me = ref.watch(myUserIdProvider);
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.sm),
            child: Text('Forward to…', style: theme.textTheme.titleMedium),
          ),
          if (items.isEmpty)
            const Padding(padding: EdgeInsets.all(Space.lg), child: Text('No other chats yet.'))
          else
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final i in items)
                  Builder(builder: (context) {
                    final title = chatTitle(i.chat, i.members, users, me);
                    final group = i.chat.kind == 'group';
                    return ListTile(
                      key: Key('forward-to-${i.chat.id}'),
                      leading: PersonAvatar(
                        label: title,
                        colorKey: group ? i.chat.id : (otherMember(i.chat, i.members, me) ?? i.chat.id),
                        userId: group ? null : otherMember(i.chat, i.members, me),
                        group: group,
                        chatId: i.chat.id,
                        chatPhotoKey: i.chat.avatarKey,
                        radius: 20,
                      ),
                      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => Navigator.pop(context, (id: i.chat.id, title: title)),
                    );
                  }),
              ]),
            ),
        ]),
      ),
    );
  }
}
