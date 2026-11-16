import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/db/chat_db.dart';
import '../../chat/providers.dart';
import '../../chat/reactions.dart';
import '../../media/photo.dart';
import '../../media/media_service.dart';
import '../../media/photo_picker.dart';
import '../../media/providers.dart';
import '../../voice/providers.dart';
import '../../voice/recording.dart';
import '../../voice/waveform.dart';
import '../../theme/tokens.dart';
import '../../widgets/common.dart';
import '../../widgets/person_avatar.dart';
import '../../widgets/typing_dots.dart';
import 'message_bubble.dart';
import 'record_bar.dart';
import 'timeline.dart';

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
  late final VoiceRecording _recording;
  late final ProviderContainer _container;

  /// Where a recording goes, fixed when it starts: the clip still sends if the user leaves the chat
  /// while the recorder is finishing (when `ref` can no longer be used).
  MediaService? _voiceTarget;
  bool _empty = true;
  RecordingStatus _recStatus = RecordingStatus.idle;

  @override
  void initState() {
    super.initState();
    _recording = VoiceRecording(ref.read(voiceRecorderFactoryProvider), onAutoStop: _sendVoice);
    _container = ProviderScope.containerOf(context, listen: false);
    _recording.addListener(() {
      if (_recording.status != _recStatus && mounted) setState(() => _recStatus = _recording.status);
    });
    // Desktop (and web on a desktop OS): type straight away. Phones and tablets wait for a tap, since
    // focus would raise the on-screen keyboard.
    if ({TargetPlatform.linux, TargetPlatform.macOS, TargetPlatform.windows}.contains(defaultTargetPlatform)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
    _text.addListener(() {
      final empty = _text.text.trim().isEmpty;
      if (empty != _empty && mounted) setState(() => _empty = empty);
    });
  }

  @override
  void dispose() {
    _recording.dispose(); // discards an unsent recording (one being finished still sends)
    // No voice keeps playing without its bubble on screen (after this frame: providers cannot change
    // while the tree is building).
    final container = _container;
    unawaited(Future(() async {
      try {
        await container.read(voicePlaybackProvider.notifier).stop();
      } on StateError {
        // the whole app went away
      }
    }));
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    unawaited(ref.read(voicePlaybackProvider.notifier).stop());
    _voiceTarget = ref.read(mediaServiceProvider);
    await _recording.start();
    switch (_recording.status) {
      case RecordingStatus.denied:
        _snack("FamChat can't use the microphone. Allow microphone access in your device settings.");
      case RecordingStatus.failed:
        _snack("Couldn't start recording.");
      default:
        break;
    }
  }

  Future<void> _finishRecording() async {
    final clip = await _recording.finish();
    if (clip == null) {
      _snack("Couldn't record that voice message.");
      return;
    }
    await _sendVoice(clip);
  }

  Future<void> _sendVoice(RecordedVoice clip) async {
    final media = _voiceTarget;
    if (media == null) {
      _snack("Couldn't send that voice message.");
      return;
    }
    try {
      await media.sendVoice(widget.chatId, clip);
    } on ArgumentError {
      _snack("That voice message can't be sent.");
    } catch (_) {
      _snack("Couldn't send that voice message.");
    }
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

  /// Attach, the text field, and Send (or the mic while the field is empty and recording works here).
  Widget _composer(bool canRecord) {
    final scheme = Theme.of(context).colorScheme;
    final t = FamTokens.of(context);
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      IconButton(
        tooltip: 'Attach photo',
        icon: const Icon(Icons.add_photo_alternate_outlined),
        style: IconButton.styleFrom(fixedSize: const Size.square(48)),
        onPressed: _attach,
      ),
      Expanded(
        child: CallbackShortcuts(
          bindings: {
            if (_enterSends) const SingleActivator(LogicalKeyboardKey.enter): _send,
            // With a draft, Esc only leaves the field; a second Esc (the shell's) closes the chat.
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                _text.text.isEmpty ? context.go('/') : _focus.unfocus(),
          },
          child: TextField(
            key: const Key('composer'),
            controller: _text,
            focusNode: _focus,
            minLines: 1,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            keyboardType: TextInputType.multiline,
            style: Theme.of(context).textTheme.bodyLarge,
            decoration: InputDecoration(
              hintText: 'Message',
              filled: true,
              fillColor: t.theirsBubble,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide(color: scheme.outlineVariant),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide(color: scheme.outlineVariant),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide(color: scheme.tertiary, width: 1.5),
              ),
            ),
            onChanged: (_) => ref.read(chatSyncProvider)?.typing(widget.chatId),
          ),
        ),
      ),
      const SizedBox(width: Space.sm),
      if (_empty && canRecord)
        IconButton.filled(
          tooltip: 'Record voice message',
          style: IconButton.styleFrom(fixedSize: const Size.square(48)),
          icon: const Icon(Icons.mic_rounded),
          onPressed: _startRecording,
        )
      else
        IconButton.filled(
          tooltip: 'Send',
          style: IconButton.styleFrom(fixedSize: const Size.square(48)),
          icon: const Icon(Icons.arrow_upward_rounded),
          onPressed: _send,
        ),
    ]);
  }

  /// Ids on screen when the conversation opened: those don't animate in, later ones do.
  Set<String>? _initialIds;

  /// Ids that have already played their entrance (rows are rebuilt as the list shifts or scrolls).
  final _animated = <String>{};

  @override
  Widget build(BuildContext context) {
    final chatId = widget.chatId;
    final chat = ref.watch(chatProvider(chatId)).value;
    final members = ref.watch(membersProvider(chatId)).value ?? const <MemberRow>[];
    final users = ref.watch(usersProvider).value ?? const <String, UserRow>{};
    final me = ref.watch(myUserIdProvider);
    final online = ref.watch(onlineProvider).value ?? const <String>{};
    final typing = ref.watch(typingProvider(chatId)).value ?? const <String>{};
    final loaded = ref.watch(messagesProvider(chatId));
    final messages = loaded.value ?? const <MessageRow>[];
    if (_initialIds == null && loaded.hasValue) _initialIds = {for (final m in messages) m.id};
    ref.listen(messagesProvider(chatId), (_, _) => _markRead());
    final theme = Theme.of(context);
    final tokens = FamTokens.of(context);
    final canRecord = ref.watch(voiceRecordingSupportedProvider).value ?? false;

    if (chat == null) {
      return Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: widget.showBack ? BackButton(onPressed: () => context.go('/')) : null,
        ),
        body: EmptyState(
          art: Icon(Icons.forum_outlined, size: 48, color: theme.colorScheme.onSurfaceVariant),
          title: 'This chat is no longer available.',
        ),
      );
    }
    final title = chatTitle(chat, members, users, me);
    final other = otherMember(chat, members, me);
    final group = chat.kind == 'group';
    final otherOnline = other != null && online.contains(other);
    final subtitle = group ? membersLabel(members.length) : (otherOnline ? 'Online' : null);
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
    final entries = buildTimeline(visible).reversed.toList(); // the list runs bottom-up
    final now = DateTime.now();
    final sync = ref.read(chatSyncProvider);
    const avatarSpace = 40.0;

    Widget entry(TimelineEntry e) => switch (e) {
          DayEntry(:final day) => DaySeparator(key: ValueKey('day-${day.millisecondsSinceEpoch}'), label: dayLabel(day, now)),
          MessageEntry(message: final m, :final firstInGroup, :final lastInGroup) => AppearIn(
              key: ValueKey(m.id),
              animate: _initialIds != null && !_initialIds!.contains(m.id) && _animated.add(m.id),
              child: MessageBubble(
                message: m,
                mine: m.senderUserId == me,
                senderName: group && m.senderUserId != me && firstInGroup ? users[m.senderUserId]?.name ?? 'Someone' : null,
                reactions: reactions[m.id] ?? const {},
                myUserId: me,
                onReact: (e) => sync?.react(chatId, m.id, e),
                onRetry: () => sync?.retry(m.id),
                footer: seenFooter(m),
                firstInGroup: firstInGroup,
                lastInGroup: lastInGroup,
                avatarSpace: group ? avatarSpace : 0,
                avatar: group && m.senderUserId != me && lastInGroup
                    ? PersonAvatar(label: users[m.senderUserId]?.name ?? '?', colorKey: m.senderUserId, radius: 15)
                    : null,
              ),
            ),
        };

    return Scaffold(
        backgroundColor: tokens.chatBackdrop,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: widget.showBack ? BackButton(onPressed: () => context.go('/')) : null,
          titleSpacing: widget.showBack ? 0 : Space.lg,
          shape: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
          title: Row(children: [
            PersonAvatar(label: title, colorKey: group ? chat.id : (other ?? chat.id), group: group, online: otherOnline, radius: 20),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(title, overflow: TextOverflow.ellipsis, maxLines: 1, style: theme.textTheme.titleMedium),
                if (subtitle != null)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
              ]),
            ),
          ]),
          actions: [
            IconButton(
              tooltip: 'Chat info',
              icon: const Icon(Icons.info_outline_rounded),
              onPressed: () => context.go('/chats/$chatId/info'),
            ),
            const SizedBox(width: Space.xs),
          ],
        ),
        body: LayoutBuilder(builder: (context, c) {
          // Wide panes keep the messages in a readable column; the backdrop runs edge to edge.
          final side = math.max(Space.md, (c.maxWidth - Widths.conversation) / 2);
          return Column(children: [
            for (final r in resets)
              NoticeCard(
                key: Key('reset-banner-${r.id}'),
                icon: Icons.restart_alt_rounded,
                text: resetBannerText(r, users),
                actions: [
                  TextButton(
                    key: Key('dismiss-reset-${r.id}'),
                    onPressed: () => ref.read(chatDbProvider).dismissResetBanner(r.id, chatId),
                    child: const Text('OK'),
                  ),
                ],
              ),
            for (final u in changed)
              NoticeCard(
                tone: NoticeTone.warning,
                icon: Icons.gpp_maybe_outlined,
                text: "${u.name}'s security key changed. This happens after an account reset.",
                actions: [
                  TextButton(
                    onPressed: () => ref.read(chatSyncProvider)?.acknowledgeIdentity(u.id),
                    style: TextButton.styleFrom(foregroundColor: theme.colorScheme.onErrorContainer),
                    child: const Text('OK'),
                  ),
                ],
              ),
            Expanded(
              child: visible.isEmpty
                  ? EmptyState(
                      art: PersonAvatar(
                        label: title,
                        colorKey: group ? chat.id : (other ?? chat.id),
                        group: group,
                        radius: 36,
                      ),
                      title: 'Say hello 👋',
                      body: group ? 'Messages here go to everyone in $title.' : 'Only you and $title can read this chat.',
                    )
                  : ListView.builder(
                      reverse: true,
                      padding: EdgeInsets.fromLTRB(side, Space.sm, side, Space.sm),
                      itemCount: entries.length,
                      itemBuilder: (context, i) => entry(entries[i]),
                      // New messages go in at index 0 of this bottom-up list; matching keys to their new
                      // index keeps every other row (and its state) instead of rebuilding them all.
                      findChildIndexCallback: (key) {
                        final id = (key as ValueKey<Object?>).value;
                        final i = entries.indexWhere((e) => switch (e) {
                              MessageEntry(:final message) => message.id == id,
                              DayEntry(:final day) => 'day-${day.millisecondsSinceEpoch}' == id,
                            });
                        return i < 0 ? null : i;
                      },
                    ),
            ),
            if (typingNames.isNotEmpty)
              Padding(
                padding: EdgeInsets.fromLTRB(side + (group ? avatarSpace : 0), 0, side, Space.xs),
                child: Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: tokens.theirsBubble,
                      borderRadius: BorderRadius.circular(Radii.lg),
                      border: Border.all(color: tokens.theirsBorder),
                    ),
                    child: TypingDots(color: tokens.theirsMeta),
                  ),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: Text(
                      typingNames.length == 1
                          ? '${typingNames.single} is typing…'
                          : '${typingNames.join(', ')} are typing…',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ]),
              ),
            if (_preparing > 0) const LinearProgressIndicator(key: Key('preparing-photo')),
            Material(
              color: theme.colorScheme.surface,
              shape: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(math.max(Space.xs, side - Space.md), Space.sm, math.max(Space.sm, side - Space.xs), Space.sm),
                  child: _recording.active
                      ? RecordBar(recording: _recording, onDiscard: _recording.cancel, onSend: _finishRecording)
                      : _composer(canRecord),
                ),
              ),
            ),
          ]);
        }),
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
