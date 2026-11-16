import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/db/chat_db.dart';
import '../../chat/providers.dart';
import '../../chat/reactions.dart';
import '../../media/photo.dart';
import '../../media/photo_picker.dart';
import '../../media/providers.dart';
import 'chat_list.dart' show ChatAvatar;
import 'message_bubble.dart';

/// One chat: header, messages, typing line and the composer.
class ConversationView extends ConsumerStatefulWidget {
  const ConversationView({super.key, required this.chatId, this.showBack = true});

  final String chatId;
  final bool showBack;

  @override
  ConsumerState<ConversationView> createState() => _ConversationViewState();
}

class _ConversationViewState extends ConsumerState<ConversationView> {
  final _text = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _markRead() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(chatSyncProvider)?.markRead(widget.chatId));
    });
  }

  Future<void> _send() async {
    final sync = ref.read(chatSyncProvider);
    final text = _text.text;
    if (sync == null || text.trim().isEmpty) return;
    try {
      await sync.sendText(widget.chatId, text);
      _text.clear();
    } on ArgumentError {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That message is too long.')));
      }
    }
    _focus.requestFocus();
  }

  /// Photos being compressed and encrypted (before they appear in the list).
  int _preparing = 0;

  Future<void> _attach() async {
    final media = ref.read(mediaServiceProvider);
    if (media == null) return;
    var camera = false;
    if (cameraAvailable) {
      final choice = await showModalBottomSheet<bool>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Photo library'),
              onTap: () => Navigator.pop(context, false),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Camera'),
              onTap: () => Navigator.pop(context, true),
            ),
          ]),
        ),
      );
      if (choice == null) return;
      camera = choice;
    }
    final List<Uint8List> picked;
    try {
      picked = await ref.read(photoPickerProvider)(camera: camera);
    } catch (e) {
      _snack("Couldn't open the photo picker.");
      return;
    }
    var failed = 0;
    for (final bytes in picked) {
      setState(() => _preparing++);
      try {
        await media.sendPhoto(widget.chatId, bytes);
      } on UnsupportedImageException {
        failed++;
      } on ArgumentError {
        failed++;
      } finally {
        if (mounted) setState(() => _preparing--);
      }
    }
    if (failed > 0) _snack(failed == 1 ? "That image can't be sent." : "$failed images can't be sent.");
  }

  void _snack(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  bool get _enterSends =>
      kIsWeb || {TargetPlatform.linux, TargetPlatform.macOS, TargetPlatform.windows}.contains(defaultTargetPlatform);

  @override
  Widget build(BuildContext context) {
    final chatId = widget.chatId;
    final chat = ref.watch(chatProvider(chatId)).value;
    final members = ref.watch(membersProvider(chatId)).value ?? const <MemberRow>[];
    final users = ref.watch(usersProvider).value ?? const <String, UserRow>{};
    final me = ref.watch(myUserIdProvider);
    final online = ref.watch(onlineProvider).value ?? const <String>{};
    final typing = ref.watch(typingProvider(chatId)).value ?? const <String>{};
    final messages = ref.watch(messagesProvider(chatId)).value ?? const <MessageRow>[];
    ref.listen(messagesProvider(chatId), (_, _) => _markRead());
    final theme = Theme.of(context);

    if (chat == null) {
      return Scaffold(
        appBar: AppBar(automaticallyImplyLeading: widget.showBack),
        body: const Center(child: Text('This chat is no longer available.')),
      );
    }
    final title = chatTitle(chat, members, users, me);
    final other = otherMember(chat, members, me);
    final group = chat.kind == 'group';
    final subtitle = group
        ? '${members.length} members'
        : (other != null && online.contains(other) ? 'Online' : null);
    final resets = ref.watch(resetBannersProvider(chatId)).value ?? const <ResetRow>[];
    final changed = [
      for (final m in members)
        if (m.userId != me && users[m.userId] != null && users[m.userId]!.identityPub != users[m.userId]!.trustedIdentityPub)
          users[m.userId]!,
    ];

    final reactions = aggregateReactions(messages);
    final visible = messages.where((m) => m.kind != 'reaction').toList();
    final others = members.where((m) => m.userId != me).toList();
    final lastMineSent = visible.lastWhere((m) => m.senderUserId == me && m.seq != null, orElse: () => _none).id;
    String? seenFooter(MessageRow m) {
      if (m.id != lastMineSent || others.isEmpty) return null;
      final seen = others.where((o) => o.lastReadSeq >= m.seq!).length;
      if (seen == 0) return null;
      if (seen == others.length) return 'Seen';
      return 'Seen by $seen';
    }

    final typingNames = [for (final u in typing) if (u != me) users[u]?.name ?? 'Someone'];

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: widget.showBack ? BackButton(onPressed: () => context.go('/')) : null,
        titleSpacing: widget.showBack ? 0 : null,
        title: Row(children: [
          ChatAvatar(label: title, group: group, online: other != null && online.contains(other), radius: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, overflow: TextOverflow.ellipsis),
              if (subtitle != null) Text(subtitle, style: theme.textTheme.labelSmall),
            ]),
          ),
        ]),
        actions: [
          IconButton(
            tooltip: 'Chat info',
            icon: const Icon(Icons.info_outline),
            onPressed: () => context.go('/chats/$chatId/info'),
          ),
        ],
      ),
      body: Column(children: [
        for (final r in resets)
          MaterialBanner(
            key: Key('reset-banner-${r.id}'),
            leading: Icon(Icons.restart_alt_rounded, color: theme.colorScheme.primary),
            content: Text(resetBannerText(r, users)),
            actions: [
              TextButton(
                key: Key('dismiss-reset-${r.id}'),
                onPressed: () => ref.read(chatDbProvider).dismissResetBanner(r.id, chatId),
                child: const Text('OK'),
              ),
            ],
          ),
        for (final u in changed)
          MaterialBanner(
            leading: Icon(Icons.gpp_maybe_outlined, color: theme.colorScheme.error),
            content: Text("${u.name}'s security key changed. This happens after an account reset."),
            actions: [
              TextButton(
                onPressed: () => ref.read(chatSyncProvider)?.acknowledgeIdentity(u.id),
                child: const Text('OK'),
              ),
            ],
          ),
        Expanded(
          child: visible.isEmpty
              ? Center(child: Text('Say hello 👋', style: theme.textTheme.bodyLarge))
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: visible.length,
                  itemBuilder: (context, i) {
                    final m = visible[visible.length - 1 - i];
                    final mine = m.senderUserId == me;
                    final sync = ref.read(chatSyncProvider);
                    return MessageBubble(
                      key: ValueKey(m.id),
                      message: m,
                      mine: mine,
                      senderName: group && !mine ? users[m.senderUserId]?.name ?? 'Someone' : null,
                      reactions: reactions[m.id] ?? const {},
                      myUserId: me,
                      onReact: (e) => sync?.react(chatId, m.id, e),
                      onRetry: () => sync?.retry(m.id),
                      footer: seenFooter(m),
                    );
                  },
                ),
        ),
        if (typingNames.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                typingNames.length == 1 ? '${typingNames.single} is typing…' : '${typingNames.join(', ')} are typing…',
                style: theme.textTheme.labelMedium?.copyWith(fontStyle: FontStyle.italic),
              ),
            ),
          ),
        if (_preparing > 0) const LinearProgressIndicator(key: Key('preparing-photo')),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 8, 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              IconButton(tooltip: 'Attach photo', icon: const Icon(Icons.add_photo_alternate_outlined), onPressed: _attach),
              Expanded(
                child: CallbackShortcuts(
                  bindings: {
                    if (_enterSends) const SingleActivator(LogicalKeyboardKey.enter): _send,
                  },
                  child: TextField(
                    key: const Key('composer'),
                    controller: _text,
                    focusNode: _focus,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    keyboardType: TextInputType.multiline,
                    decoration: const InputDecoration(hintText: 'Message', border: OutlineInputBorder()),
                    onChanged: (_) => ref.read(chatSyncProvider)?.typing(chatId),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton.filled(tooltip: 'Send', icon: const Icon(Icons.send), onPressed: _send),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// "Mom's account was reset by Michael." (spec "Admin recovery"), or the recovery-code variant.
String resetBannerText(ResetRow r, Map<String, UserRow> users) {
  final who = users[r.userId]?.name ?? 'Someone';
  if (r.signerKind == 'recovery') {
    return '$who recovered their admin account with the recovery code. Their old devices were signed out.';
  }
  return "$who's account was reset by ${users[r.signerUserId]?.name ?? 'an admin'}. Their old devices were signed out.";
}

final _none = MessageRow(
  id: '',
  chatId: '',
  seq: null,
  senderUserId: '',
  senderDeviceId: '',
  kind: '',
  body: null,
  targetId: null,
  envelope: null,
  createdAt: 0,
  state: '',
);
