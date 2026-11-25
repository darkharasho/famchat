import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/db/chat_db.dart';
import '../../chat/emoji/shortcodes.dart';
import '../../chat/files.dart' show fileOf;
import '../../chat/plaintext.dart';
import '../../chat/polls.dart' show pollOf;
import '../../gifs/gif_picker.dart';
import '../../theme/motion.dart';
import '../../theme/tokens.dart';
import '../../theme/app_theme.dart';
import '../../widgets/link_text.dart';
import '../../settings/time_format.dart' show clockTime;
import 'album_grid.dart';
import 'file_bubble.dart';
import 'photo_view.dart';
import 'link_preview_card.dart';
import 'video_view.dart';
import 'voice_bubble.dart';

const reactionEmoji = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/// Desktop and web get a hover button for reactions; touch devices long-press.
bool get hoverReactions =>
    kIsWeb || {TargetPlatform.linux, TargetPlatform.macOS, TargetPlatform.windows}.contains(defaultTargetPlatform);

/// The row of reaction emoji; tapping one pops the sheet with it.
Widget _reactionRow(BuildContext context, String? current) {
  final s = Theme.of(context).colorScheme;
  return Wrap(alignment: WrapAlignment.center, spacing: Space.sm, runSpacing: Space.sm, children: [
    for (final e in reactionEmoji)
      IconButton(
        isSelected: e == current,
        tooltip: e == current ? 'Remove $e' : 'React $e',
        style: IconButton.styleFrom(
          minimumSize: const Size(56, 56),
          backgroundColor: e == current ? s.secondaryContainer : s.surfaceContainer,
        ),
        onPressed: () => Navigator.pop(context, e),
        icon: Text(e, style: const TextStyle(fontSize: 28)),
      ),
  ]);
}

/// Shows the emoji picker; returns the emoji picked, or null.
Future<String?> pickReaction(BuildContext context, {String? current}) => showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.xl),
          child: _reactionRow(context, current),
        ),
      ),
    );

/// What can be done to a message besides reacting.
enum MessageAction { reply, pin, star, remind, forward, save, transcribe, copy, readBy, edit, delete }

/// The message a reply quotes, as its bubble shows it.
class QuotedMessage {
  const QuotedMessage({required this.id, required this.sender, required this.snippet});
  final String id, sender, snippet;
}

/// How many of the chat's other members have read one of my sent messages.
class ReadReceipt {
  const ReadReceipt({required this.readBy, required this.of});
  final int readBy, of;

  /// Two ticks once anyone has read it (as Telegram does in groups); one while nobody has.
  bool get read => readBy > 0;

  String get label => !read ? 'Sent' : (of <= 1 || readBy >= of ? 'Read' : 'Read by $readBy of $of');
}

/// One message: bubble, sender (groups), time, delivery state and reaction chips.
class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.mine,
    required this.senderName,
    required this.reactions,
    required this.myUserId,
    required this.onReact,
    required this.onRetry,
    this.receipt,
    this.firstInGroup = true,
    this.lastInGroup = true,
    this.avatar,
    this.avatarSpace = 0,
    this.shownText,
    this.mentionNames = const [],
    this.linkPreview,
    this.transcript,
    this.localTranscript = false,
    this.transcribing = false,
    this.onTranscribe,
    this.edited = false,
    this.deleted = false,
    this.quote,
    this.onOpenQuote,
    this.onReply,
    this.onForward,
    this.forwarded = false,
    this.onEdit,
    this.onDelete,
    this.onReadBy,
    this.highlighted = false,
    this.onPin,
    this.pinned = false,
    this.onStar,
    this.starred = false,
    this.onRemind,
    this.reminderAt,
    this.album,
    this.onOpenAlbumItem,
    this.onOpenMedia,
    this.custom,
    this.onSave,
  });

  /// Files: "Save as…" (a copy where the person picks).
  final VoidCallback? onSave;

  /// What the bubble shows for a kind with its own look (a poll), in place of text; not while deleted.
  final Widget? custom;

  /// Photos and videos sent together, oldest first, shown as one grid; [message] is the last of
  /// them (it carries the caption, and the bubble's actions apply to it).
  final List<MessageRow>? album;
  final void Function(int index)? onOpenAlbumItem;

  /// Opens a photo or video full screen; null opens just this one.
  final VoidCallback? onOpenMedia;

  /// Pins it for everyone (or unpins it, when [pinned]).
  final VoidCallback? onPin;
  final bool pinned;

  /// Stars it for me (or unstars it, when [starred]); a ★ shows by the time while starred.
  final VoidCallback? onStar;
  final bool starred;

  /// "Remind me" (or, with [reminderAt], change or clear it); a bell shows by the time while one is
  /// set, and tapping it does the same. Reminders are mine alone.
  final VoidCallback? onRemind;

  /// When my reminder on it comes (Unix ms), or null.
  final int? reminderAt;

  /// My sent messages in groups: who has read it.
  final VoidCallback? onReadBy;

  final MessageRow message;
  final bool mine;

  /// Shown above others' bubbles in groups; null hides it.
  final String? senderName;

  /// emoji → user ids.
  final Map<String, Set<String>> reactions;
  final String? myUserId;

  /// Called with the emoji to set ('' removes).
  final ValueChanged<String> onReact;
  final VoidCallback onRetry;

  /// My sent messages: one tick, or two once read, beside the time. Null for others' messages.
  final ReadReceipt? receipt;

  /// Where this bubble sits in a run from one sender (see timeline.dart).
  final bool firstInGroup, lastInGroup;

  /// The sender's avatar beside the last bubble of their run (others, in groups).
  final Widget? avatar;

  /// Width kept free on the sender's side for [avatar], so a run lines up.
  final double avatarSpace;

  /// The text to show (its latest edit) instead of the stored one.
  final String? shownText;

  /// Names of the people this text @mentions (bold in it).
  final List<String> mentionNames;

  /// The card for the text's link, if the sender made one.
  final LinkPreview? linkPreview;

  /// A voice message's transcript, shown under the clip.
  final String? transcript;

  /// [transcript] was made on this device; [transcribing]: one is being made now.
  final bool localTranscript, transcribing;

  /// Voice messages without a transcript: "Transcribe" (on this device).
  final VoidCallback? onTranscribe;

  /// Shows "edited" in the bubble; [deleted] shows the message as deleted.
  final bool edited, deleted;

  /// The message this one replies to, shown above it; tapping it calls [onOpenQuote].
  final QuotedMessage? quote;
  final VoidCallback? onOpenQuote;

  /// Null hides the action.
  final VoidCallback? onReply, onForward, onEdit, onDelete;

  /// A copy forwarded from another message: labelled so.
  final bool forwarded;

  /// Briefly tinted after jumping to it.
  final bool highlighted;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  bool _hover = false;

  String? get _myEmoji =>
      widget.reactions.entries.where((e) => e.value.contains(widget.myUserId)).map((e) => e.key).firstOrNull;

  Future<void> _pick() async {
    final e = await pickReaction(context, current: _myEmoji);
    if (e != null) widget.onReact(e == _myEmoji ? '' : e);
  }

  /// The text Copy copies, or null.
  String? get _copyText => widget.deleted
      ? null
      : widget.message.kind == 'text'
          ? _text
          : widget.shownText;

  bool get _hasActions =>
      _reactable ||
      widget.onReply != null ||
      widget.onForward != null ||
      widget.onSave != null ||
      widget.onTranscribe != null ||
      widget.onEdit != null ||
      widget.onDelete != null ||
      _copyText != null;

  /// Touch: a sheet with the reactions and the actions.
  Future<void> _openActions() async {
    final picked = await showModalBottomSheet<Object>(
      context: context,
      // As tall as its rows (up to most of the screen): the default cap of 9/16 clips them on phones.
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: Space.md),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (_reactable)
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.md),
                child: _reactionRow(context, _myEmoji),
              ),
            for (final a in _actions) _actionTile(context, a),
          ]),
        ),
      ),
    );
    _handle(picked);
  }

  List<MessageAction> get _actions => [
        if (widget.onReply != null) MessageAction.reply,
        if (widget.onPin != null) MessageAction.pin,
        if (widget.onStar != null) MessageAction.star,
        if (widget.onRemind != null) MessageAction.remind,
        if (widget.onForward != null) MessageAction.forward,
        if (widget.onSave != null) MessageAction.save,
        if (widget.onTranscribe != null) MessageAction.transcribe,
        if (_copyText != null) MessageAction.copy,
        if (widget.onReadBy != null) MessageAction.readBy,
        if (widget.onEdit != null) MessageAction.edit,
        if (widget.onDelete != null) MessageAction.delete,
      ];

  (IconData, String) _look(MessageAction a) => switch (a) {
        MessageAction.reply => (Icons.reply_rounded, 'Reply'),
        MessageAction.pin => widget.pinned
            ? (Icons.push_pin_rounded, 'Unpin')
            : (Icons.push_pin_outlined, 'Pin for everyone'),
        MessageAction.star => widget.starred ? (Icons.star_rounded, 'Unstar') : (Icons.star_outline_rounded, 'Star'),
        MessageAction.remind => widget.reminderAt != null
            ? (Icons.notifications_active_outlined, 'Change reminder')
            : (Icons.notification_add_outlined, 'Remind me'),
        MessageAction.forward => (Icons.shortcut_rounded, 'Forward'),
        MessageAction.save => (Icons.download_rounded, hoverReactions ? 'Save as…' : 'Save'),
        MessageAction.transcribe => (Icons.subtitles_outlined, 'Transcribe'),
        MessageAction.copy => (Icons.copy_rounded, 'Copy'),
        MessageAction.readBy => (Icons.done_all_rounded, 'Read by'),
        MessageAction.edit => (Icons.edit_outlined, 'Edit'),
        MessageAction.delete => (Icons.delete_outline_rounded, 'Delete'),
      };

  Widget _actionTile(BuildContext context, MessageAction a) {
    final (icon, label) = _look(a);
    final danger = a == MessageAction.delete ? Theme.of(context).colorScheme.error : null;
    return ListTile(
      leading: Icon(icon, color: danger),
      title: Text(label, style: danger == null ? null : TextStyle(color: danger)),
      onTap: () => Navigator.pop(context, a),
    );
  }

  /// Desktop: the actions as a menu at [global] (right-click, or the ⋯ button).
  Future<void> _menuAt(Offset global) async {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final picked = await showMenu<Object>(
      context: context,
      position: RelativeRect.fromRect(global & Size.zero, Offset.zero & overlay.size),
      items: [
        if (_reactable) const PopupMenuItem(value: 'react', child: ListTile(leading: Icon(Icons.add_reaction_outlined), title: Text('React'))),
        for (final a in _actions)
          PopupMenuItem(
            value: a,
            child: Builder(builder: (context) {
              final (icon, label) = _look(a);
              final danger = a == MessageAction.delete ? Theme.of(context).colorScheme.error : null;
              return ListTile(
                leading: Icon(icon, color: danger),
                title: Text(label, style: danger == null ? null : TextStyle(color: danger)),
              );
            }),
          ),
      ],
    );
    if (picked == 'react') return _pick();
    _handle(picked);
  }

  void _handle(Object? picked) {
    switch (picked) {
      case String e:
        widget.onReact(e == _myEmoji ? '' : e);
      case MessageAction.reply:
        widget.onReply?.call();
      case MessageAction.pin:
        widget.onPin?.call();
      case MessageAction.star:
        widget.onStar?.call();
      case MessageAction.remind:
        widget.onRemind?.call();
      case MessageAction.forward:
        widget.onForward?.call();
      case MessageAction.save:
        widget.onSave?.call();
      case MessageAction.transcribe:
        widget.onTranscribe?.call();
      case MessageAction.copy:
        final text = _copyText;
        if (text == null) return;
        unawaited(Clipboard.setData(ClipboardData(text: text)));
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Copied')));
      case MessageAction.readBy:
        widget.onReadBy?.call();
      case MessageAction.edit:
        widget.onEdit?.call();
      case MessageAction.delete:
        widget.onDelete?.call();
    }
  }

  String get _text {
    final m = widget.message;
    if (widget.deleted) return 'This message was deleted.';
    return switch (m.kind) {
      'text' => widget.shownText ?? (jsonDecode(m.body!) as Map)['text'] as String,
      // A poll that didn't go out (sent ones show as [custom]).
      'poll' => '📊 ${pollOf(m)?.question ?? 'Poll'}',
      'undecryptable' => 'Waiting for this message…',
      'invalid' => "This message couldn't be verified.",
      _ => 'This message needs a newer version of FamChat.',
    };
  }

  /// The photo in this message, or null (not a photo, or a body this version can't read).
  PhotoBody? get _photo {
    final m = widget.message;
    if (widget.deleted || m.kind != 'photo' || m.body == null) return null;
    try {
      final p = Plaintext.decode(utf8.encode(m.body!));
      return p is PhotoBody ? p : null;
    } on FormatException {
      return null;
    }
  }

  /// The video in this message, or null.
  VideoBody? get _video {
    final m = widget.message;
    if (widget.deleted || m.kind != 'video' || m.body == null) return null;
    try {
      final p = Plaintext.decode(utf8.encode(m.body!));
      return p is VideoBody ? p : null;
    } on FormatException {
      return null;
    }
  }

  /// The GIF in this message, or null.
  GifBody? get _gif {
    final m = widget.message;
    if (widget.deleted || m.kind != 'gif' || m.body == null) return null;
    try {
      final p = Plaintext.decode(utf8.encode(m.body!));
      return p is GifBody ? p : null;
    } on FormatException {
      return null;
    }
  }

  /// The voice clip in this message, or null.
  VoiceBody? get _voice {
    final m = widget.message;
    if (widget.deleted || m.kind != 'voice' || m.body == null) return null;
    try {
      final p = Plaintext.decode(utf8.encode(m.body!));
      return p is VoiceBody ? p : null;
    } on FormatException {
      return null;
    }
  }

  bool get _reactable =>
      !widget.deleted && const {'text', 'photo', 'voice', 'gif', 'video', 'poll', 'file'}.contains(widget.message.kind) && widget.message.seq != null;

  BorderRadius get _radius {
    const big = Radius.circular(Radii.lg), small = Radius.circular(Radii.xs);
    final top = widget.firstInGroup ? big : small;
    // The sender's side stays tight at the bottom: the run "points" at its sender.
    return widget.mine
        ? BorderRadius.only(topLeft: big, bottomLeft: big, topRight: top, bottomRight: small)
        : BorderRadius.only(topRight: big, bottomRight: big, topLeft: top, bottomLeft: small);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = FamTokens.of(context);
    final m = widget.message;
    final photo = _photo;
    final voice = _voice;
    final gif = _gif;
    final video = _video;
    final file = widget.deleted ? null : fileOf(m);
    final custom = widget.deleted ? null : widget.custom;
    final special =
        widget.deleted || (m.kind != 'text' && photo == null && voice == null && gif == null && video == null && file == null && custom == null);
    // Edge-to-edge media: little padding around it.
    final album = widget.deleted ? null : widget.album;
    final visual = photo != null || gif != null || video != null || album != null;
    final mine = widget.mine;
    final bg = mine ? t.mineBubble : t.theirsBubble;
    final fg = mine ? t.onMineBubble : t.onTheirsBubble;
    final meta = mine ? t.mineMeta : t.theirsMeta;
    final pending = m.state == 'pending';
    // My sent messages each carry their ticks (with the time), as Telegram does; others' runs show
    // the time once, under the last bubble.
    final showTime = widget.lastInGroup || widget.starred || pending || m.state == 'failed' || widget.receipt != null ||
        m.scheduledFor != null || widget.reminderAt != null;

    // "edited" stays in the bubble; the time goes under it (below).
    final showEdited = widget.edited && !widget.deleted;
    final edited = Text('edited', style: theme.textTheme.labelSmall?.copyWith(color: meta, fontStyle: FontStyle.italic));
    final dim = scheme.onSurfaceVariant;
    final timeLine = Padding(
      padding: EdgeInsets.only(
        top: 2,
        left: mine ? 0 : widget.avatarSpace + Space.xs,
        right: mine ? Space.xs : 0,
      ),
      child: Row(key: Key('time-${m.id}'), mainAxisSize: MainAxisSize.min, children: [
        if (widget.starred && !widget.deleted) ...[
          Icon(Icons.star_rounded, key: Key('star-${m.id}'), size: 13, color: const Color(0xFFE0A100), semanticLabel: 'Starred'),
          const SizedBox(width: 3),
        ],
        if (widget.reminderAt != null && !widget.deleted) ...[
          GestureDetector(
            onTap: widget.onRemind,
            behavior: HitTestBehavior.opaque,
            child: Icon(
              Icons.notifications_active_outlined,
              key: Key('bell-${m.id}'),
              size: 13,
              color: dim,
              semanticLabel: 'Reminder set',
            ),
          ),
          const SizedBox(width: 3),
        ],
        Text(
          clockTime(DateTime.fromMillisecondsSinceEpoch(m.createdAt), h24: MediaQuery.alwaysUse24HourFormatOf(context)),
          style: theme.textTheme.labelSmall?.copyWith(
            fontFamily: kDisplayFont, // plain zeros in times
            color: dim,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        // My scheduled message that went out late (the chat's key changed before its time).
        if (mine && m.scheduledFor != null && m.seq != null && m.createdAt - m.scheduledFor! > 60000) ...[
          const SizedBox(width: 4),
          Text('sent late', key: Key('sent-late-${m.id}'), style: theme.textTheme.labelSmall?.copyWith(color: dim, fontStyle: FontStyle.italic)),
        ],
        if (pending) ...[
          const SizedBox(width: 4),
          Icon(Icons.schedule_rounded, key: const Key('pending-icon'), size: 13, color: dim, semanticLabel: 'Sending'),
        ] else if (widget.receipt case final r? when m.state != 'failed') ...[
          const SizedBox(width: 3),
          Tooltip(
            message: r.label,
            child: GestureDetector(
              onTap: widget.onReadBy,
              behavior: HitTestBehavior.opaque,
              child: Icon(
                r.read ? Icons.done_all_rounded : Icons.done_rounded,
                key: Key(r.read ? 'read-icon' : 'sent-icon'),
                size: 15,
                color: r.read ? scheme.primary : dim,
                semanticLabel: r.label,
              ),
            ),
          ),
        ],
      ]),
    );

    // A photo or video's caption, under it in the same bubble.
    final caption = photo != null || video != null || album != null ? widget.shownText : null;
    final captionStyle = theme.textTheme.bodyLarge?.copyWith(color: fg);
    // As wide as the media, so it wraps under it, read from the left.
    final mediaWidth = album != null
        ? albumWidth
        : photo != null
        ? thumbSize(photo.width, photo.height).width
        : video != null
            ? thumbSize(video.width, video.height).width
            : 0.0;
    Widget? captionLine() => caption == null
        ? null
        : SizedBox(
            key: Key('caption-${m.id}'),
            width: mediaWidth,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
              child: LinkText(caption, style: captionStyle, linkColor: fg, mentions: widget.mentionNames, markdown: true),
            ),
          );

    Widget content;
    // One to three emoji alone, with nothing quoted, forwarded or previewed: shown big, with no bubble.
    var bare = false;
    if (custom != null) {
      content = custom;
    } else if (album != null) {
      content = Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        AlbumGrid(items: album, onOpen: (i) => widget.onOpenAlbumItem?.call(i)),
        ?captionLine(),
        if (showEdited) Padding(padding: const EdgeInsets.fromLTRB(8, 4, 6, 0), child: edited),
      ]);
    } else if (photo != null) {
      content = Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        PhotoThumb(body: photo, messageId: m.id, onOpen: widget.onOpenMedia ?? () => showPhotoViewer(context, photo)),
        ?captionLine(),
        if (showEdited) Padding(padding: const EdgeInsets.fromLTRB(8, 4, 6, 0), child: edited),
      ]);
    } else if (video != null) {
      content = Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        VideoThumb(body: video, messageId: m.id, onOpen: widget.onOpenMedia ?? () => showVideoViewer(context, video, m.id)),
        ?captionLine(),
        if (showEdited) Padding(padding: const EdgeInsets.fromLTRB(8, 4, 6, 0), child: edited),
      ]);
    } else if (gif != null) {
      content = Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        GifView(body: gif),
        if (showEdited) Padding(padding: const EdgeInsets.fromLTRB(8, 4, 6, 0), child: edited),
      ]);
    } else if (file != null) {
      content = Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        FileBubble(body: file, messageId: m.id, mine: mine),
        if (showEdited) edited,
      ]);
    } else if (voice != null) {
      content = Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        VoiceBubble(
            body: voice,
            messageId: m.id,
            mine: mine,
            transcript: widget.transcript,
            localTranscript: widget.localTranscript,
            transcribing: widget.transcribing),
        if (showEdited) edited,
      ]);
    } else {
      final text = _text;
      final emojiOnly = special ? null : emojiOnlyCount(text);
      // One to three emoji alone are the message: show them big.
      final big = emojiOnly != null && emojiOnly <= 3 ? const [56.0, 48.0, 40.0][emojiOnly - 1] : null;
      bare = big != null && widget.quote == null && !widget.forwarded && widget.linkPreview == null;
      final style = theme.textTheme.bodyLarge?.copyWith(
        color: special ? meta : fg,
        fontStyle: special ? FontStyle.italic : null,
        fontSize: big,
        height: big != null ? 1.2 : null,
      );
      content = Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: Space.sm,
        children: [
          if (special || big != null) Text(text, key: bare ? Key('bare-emoji-${m.id}') : null, style: style) else LinkText(text, style: style, linkColor: fg, mentions: widget.mentionNames, markdown: true),
          if (showEdited)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: bare ? Text('edited', style: edited.style?.copyWith(color: dim)) : edited,
            ),
        ],
      );
      final preview = special ? null : widget.linkPreview;
      if (preview != null) {
        content = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          content,
          const SizedBox(height: 6),
          LinkPreviewCard(key: Key('link-preview-${m.id}'), preview: preview, fg: fg, meta: meta),
        ]);
      }
    }
    final quote = widget.quote;

    final bubble = GestureDetector(
      onLongPress: _hasActions ? _openActions : null,
      onSecondaryTapUp: _hasActions && hoverReactions ? (d) => _menuAt(d.globalPosition) : null,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        padding: visual
            ? const EdgeInsets.fromLTRB(4, 4, 4, 6)
            : bare
            ? const EdgeInsets.symmetric(horizontal: 2)
            : const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: bare
            ? null
            : BoxDecoration(
                color: mine ? null : bg,
                gradient: mine ? t.mineGradient : null,
                borderRadius: _radius,
                border: mine ? null : Border.all(color: t.theirsBorder),
              ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (widget.senderName != null)
            Padding(
              padding: visual ? const EdgeInsets.fromLTRB(10, 4, 10, 6) : const EdgeInsets.only(bottom: 2),
              child: Text(
                widget.senderName!,
                style: theme.textTheme.labelMedium?.copyWith(color: bare ? dim : fg, fontWeight: FontWeight.w700),
              ),
            ),
          if (widget.forwarded && !widget.deleted)
            Padding(
              padding: visual ? const EdgeInsets.fromLTRB(10, 2, 10, 6) : const EdgeInsets.only(bottom: 2),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.shortcut_rounded, size: 14, color: meta),
                const SizedBox(width: 4),
                Text('Forwarded', style: theme.textTheme.labelSmall?.copyWith(color: meta, fontStyle: FontStyle.italic)),
              ]),
            ),
          if (quote != null && !widget.deleted)
            Padding(
              padding: visual ? const EdgeInsets.fromLTRB(4, 2, 4, 6) : const EdgeInsets.only(bottom: 6),
              child: _Quote(quote: quote, fg: fg, meta: meta, onTap: widget.onOpenQuote),
            ),
          content,
        ]),
      ),
    );

    final row = Row(
      mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (!mine && widget.avatarSpace > 0)
          SizedBox(
            width: widget.avatarSpace,
            child: Align(alignment: Alignment.bottomLeft, child: widget.avatar ?? const SizedBox()),
          ),
        if (mine && hoverReactions) _hoverButtons(),
        Flexible(child: bubble),
        if (!mine && hoverReactions) _hoverButtons(),
      ],
    );

    final indent = EdgeInsets.only(left: mine ? 0 : widget.avatarSpace);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: Motion.of(context, Motion.medium),
        decoration: BoxDecoration(
          color: widget.highlighted ? scheme.tertiaryContainer.withValues(alpha: 0.6) : scheme.tertiaryContainer.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Padding(
        // The time line under a run's last bubble takes most of the gap between runs.
        padding: EdgeInsets.only(top: widget.firstInGroup ? Space.xs : 2),
        child: Column(
          crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            row,
            if (widget.reactions.isNotEmpty && !widget.deleted)
              Padding(
                padding: indent.add(EdgeInsets.only(top: Space.xs, left: mine ? 0 : Space.sm, right: mine ? Space.sm : 0)),
                child: Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
                  for (final e in widget.reactions.entries)
                    _ReactionPill(
                      emoji: e.key,
                      count: e.value.length,
                      mine: e.value.contains(widget.myUserId),
                      onTap: () => widget.onReact(e.value.contains(widget.myUserId) ? '' : e.key),
                    ),
                ]),
              ),
            // Below the reactions, so a reaction stays next to its bubble.
            if (showTime) timeLine,
            if (m.state == 'failed')
              Padding(
                padding: indent,
                child: TextButton.icon(
                  onPressed: widget.onRetry,
                  icon: const Icon(Icons.error_outline_rounded, size: 18),
                  style: TextButton.styleFrom(
                    foregroundColor: scheme.error,
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(0, 36),
                  ),
                  label: const Text('Not sent. Tap to retry'),
                ),
              ),
          ],
        ),
      ),
      ),
    );
  }

  /// Desktop: react, reply and more, shown while hovering.
  Widget _hoverButtons() {
    if (!_hasActions) return const SizedBox.shrink();
    final buttons = [
      if (_reactable)
        IconButton(
          tooltip: 'React',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add_reaction_outlined, size: 18),
          onPressed: _pick,
        ),
      if (widget.onReply != null)
        IconButton(
          tooltip: 'Reply',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.reply_rounded, size: 18),
          onPressed: widget.onReply,
        ),
      Builder(
        builder: (context) => IconButton(
          tooltip: 'More',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.more_horiz_rounded, size: 18),
          onPressed: () {
            final box = context.findRenderObject()! as RenderBox;
            unawaited(_menuAt(box.localToGlobal(box.size.bottomLeft(Offset.zero))));
          },
        ),
      ),
    ];
    return AnimatedOpacity(
      opacity: _hover ? 1 : 0,
      duration: Motion.of(context, Motion.fast),
      child: IgnorePointer(
        ignoring: !_hover,
        child: Row(mainAxisSize: MainAxisSize.min, children: widget.mine ? buttons.reversed.toList() : buttons),
      ),
    );
  }
}

/// The quoted message at the top of a reply.
class _Quote extends StatelessWidget {
  const _Quote({required this.quote, required this.fg, required this.meta, this.onTap});

  final QuotedMessage quote;
  final Color fg, meta;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: onTap != null,
      label: 'Reply to ${quote.sender}: ${quote.snippet}',
      excludeSemantics: true,
      child: Material(
        color: fg.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Radii.sm),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: Key('reply-quote-${quote.id}'),
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(border: Border(left: BorderSide(color: fg.withValues(alpha: 0.55), width: 3))),
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(quote.sender, style: theme.textTheme.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w700)),
              Text(
                quote.snippet,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(color: meta),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _ReactionPill extends StatelessWidget {
  const _ReactionPill({required this.emoji, required this.count, required this.mine, required this.onTap});

  final String emoji;
  final int count;
  final bool mine;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = FamTokens.of(context);
    return Semantics(
      button: true,
      selected: mine,
      label: '$emoji $count${mine ? ', yours' : ''}',
      excludeSemantics: true,
      child: Material(
        color: mine ? t.badge : s.surfaceContainerLowest,
        shape: StadiumBorder(side: BorderSide(color: mine ? t.badge : s.outlineVariant)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Text(
              '$emoji $count',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: mine ? t.onBadge : s.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Today", "Yesterday", … between days.
class DaySeparator extends StatelessWidget {
  const DaySeparator({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.md),
      child: Center(
        child: Semantics(
          header: true,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 5),
            decoration: BoxDecoration(
              color: s.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(99),
              border: Border.all(color: s.outlineVariant),
            ),
            child: Text(label, style: theme.textTheme.labelMedium?.copyWith(color: s.onSurfaceVariant)),
          ),
        ),
      ),
    );
  }
}

/// "New messages": above the first message that was unread when the chat was opened.
class UnreadDivider extends StatelessWidget {
  const UnreadDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Semantics(
        header: true,
        child: Row(children: [
          Expanded(child: Divider(color: s.primary.withValues(alpha: 0.5), height: 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            child: Text('New messages', style: theme.textTheme.labelMedium?.copyWith(color: s.primary, fontWeight: FontWeight.w600)),
          ),
          Expanded(child: Divider(color: s.primary.withValues(alpha: 0.5), height: 1)),
        ]),
      ),
    );
  }
}
