import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/db/chat_db.dart';
import '../../chat/emoji/shortcodes.dart';
import '../../chat/plaintext.dart';
import '../../theme/motion.dart';
import '../../theme/tokens.dart';
import '../../theme/app_theme.dart';
import 'chat_list.dart' show clockTime;
import 'photo_view.dart';
import 'voice_bubble.dart';

const reactionEmoji = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/// Desktop and web get a hover button for reactions; touch devices long-press.
bool get hoverReactions =>
    kIsWeb || {TargetPlatform.linux, TargetPlatform.macOS, TargetPlatform.windows}.contains(defaultTargetPlatform);

/// Shows the emoji picker; returns the emoji picked, or null.
Future<String?> pickReaction(BuildContext context, {String? current}) => showModalBottomSheet<String>(
      context: context,
      builder: (context) {
        final s = Theme.of(context).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.xl),
            child: Wrap(alignment: WrapAlignment.center, spacing: Space.sm, runSpacing: Space.sm, children: [
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
            ]),
          ),
        );
      },
    );

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
    this.footer,
    this.firstInGroup = true,
    this.lastInGroup = true,
    this.avatar,
    this.avatarSpace = 0,
  });

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

  /// E.g. "Seen".
  final String? footer;

  /// Where this bubble sits in a run from one sender (see timeline.dart).
  final bool firstInGroup, lastInGroup;

  /// The sender's avatar beside the last bubble of their run (others, in groups).
  final Widget? avatar;

  /// Width kept free on the sender's side for [avatar], so a run lines up.
  final double avatarSpace;

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

  String get _text {
    final m = widget.message;
    return switch (m.kind) {
      'text' => (jsonDecode(m.body!) as Map)['text'] as String,
      'undecryptable' => 'Waiting for this message…',
      'invalid' => "This message couldn't be verified.",
      _ => 'This message needs a newer version of FamChat.',
    };
  }

  /// The photo in this message, or null (not a photo, or a body this version can't read).
  PhotoBody? get _photo {
    final m = widget.message;
    if (m.kind != 'photo' || m.body == null) return null;
    try {
      final p = Plaintext.decode(utf8.encode(m.body!));
      return p is PhotoBody ? p : null;
    } on FormatException {
      return null;
    }
  }

  /// The voice clip in this message, or null.
  VoiceBody? get _voice {
    final m = widget.message;
    if (m.kind != 'voice' || m.body == null) return null;
    try {
      final p = Plaintext.decode(utf8.encode(m.body!));
      return p is VoiceBody ? p : null;
    } on FormatException {
      return null;
    }
  }

  bool get _reactable => const {'text', 'photo', 'voice'}.contains(widget.message.kind) && widget.message.seq != null;

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
    final special = m.kind != 'text' && photo == null && voice == null;
    final mine = widget.mine;
    final bg = mine ? t.mineBubble : t.theirsBubble;
    final fg = mine ? t.onMineBubble : t.onTheirsBubble;
    final meta = mine ? t.mineMeta : t.theirsMeta;
    final pending = m.state == 'pending';
    final showTime = widget.lastInGroup || pending || m.state == 'failed';

    final metaRow = Row(mainAxisSize: MainAxisSize.min, children: [
      if (showTime)
        Text(
          clockTime(DateTime.fromMillisecondsSinceEpoch(m.createdAt)),
          style: theme.textTheme.labelSmall?.copyWith(
            fontFamily: kDisplayFont, // plain zeros in times
            color: meta,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      if (pending) ...[
        const SizedBox(width: 4),
        Icon(Icons.schedule_rounded, key: const Key('pending-icon'), size: 13, color: meta, semanticLabel: 'Sending'),
      ],
    ]);

    final Widget content;
    if (photo != null) {
      content = Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        PhotoThumb(body: photo, messageId: m.id, onOpen: () => showPhotoViewer(context, photo)),
        if (showTime) Padding(padding: const EdgeInsets.fromLTRB(8, 4, 6, 0), child: metaRow),
      ]);
    } else if (voice != null) {
      content = Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        VoiceBubble(body: voice, messageId: m.id, mine: mine),
        if (showTime) metaRow,
      ]);
    } else {
      final text = _text;
      final emojiOnly = special ? null : emojiOnlyCount(text);
      // One to three emoji alone are the message: show them big.
      final big = emojiOnly != null && emojiOnly <= 3 ? (emojiOnly == 1 ? 40.0 : 32.0) : null;
      content = Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: Space.sm,
        children: [
          Text(
            text,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: special ? meta : fg,
              fontStyle: special ? FontStyle.italic : null,
              fontSize: big,
              height: big != null ? 1.2 : null,
            ),
          ),
          if (showTime) Padding(padding: const EdgeInsets.only(top: 2), child: metaRow),
        ],
      );
    }

    final bubble = GestureDetector(
      onLongPress: _reactable ? _pick : null,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        padding: photo != null
            ? const EdgeInsets.fromLTRB(4, 4, 4, 6)
            : const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: _radius,
          border: mine ? null : Border.all(color: t.theirsBorder),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (widget.senderName != null)
            Padding(
              padding: photo != null ? const EdgeInsets.fromLTRB(10, 4, 10, 6) : const EdgeInsets.only(bottom: 2),
              child: Text(
                widget.senderName!,
                style: theme.textTheme.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w700),
              ),
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
        if (mine && hoverReactions) _hoverButton(),
        Flexible(child: bubble),
        if (!mine && hoverReactions) _hoverButton(),
      ],
    );

    final indent = EdgeInsets.only(left: mine ? 0 : widget.avatarSpace);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Padding(
        padding: EdgeInsets.only(top: widget.firstInGroup ? Space.sm : 2, bottom: widget.lastInGroup ? 2 : 0),
        child: Column(
          crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            row,
            if (widget.reactions.isNotEmpty)
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
            if (widget.footer != null)
              Padding(
                padding: const EdgeInsets.only(top: Space.xs, right: Space.xs),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.done_all_rounded, size: 14, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text(widget.footer!, style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                ]),
              ),
          ],
        ),
      ),
    );
  }

  Widget _hoverButton() => AnimatedOpacity(
        opacity: _hover ? 1 : 0,
        duration: Motion.of(context, Motion.fast),
        child: IconButton(
          tooltip: 'React',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add_reaction_outlined, size: 18),
          onPressed: _reactable ? _pick : null,
        ),
      );
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
