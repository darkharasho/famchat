import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/db/chat_db.dart';
import '../../chat/plaintext.dart';
import 'chat_list.dart' show shortTime;
import 'photo_view.dart';

const reactionEmoji = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/// Desktop and web get a hover button for reactions; touch devices long-press.
bool get hoverReactions =>
    kIsWeb || {TargetPlatform.linux, TargetPlatform.macOS, TargetPlatform.windows}.contains(defaultTargetPlatform);

/// Shows the emoji picker; returns the emoji picked, or null.
Future<String?> pickReaction(BuildContext context, {String? current}) => showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          child: Wrap(alignment: WrapAlignment.center, spacing: 4, children: [
            for (final e in reactionEmoji)
              IconButton(
                isSelected: e == current,
                style: IconButton.styleFrom(minimumSize: const Size(52, 52)),
                onPressed: () => Navigator.pop(context, e),
                icon: Text(e, style: const TextStyle(fontSize: 26)),
              ),
          ]),
        ),
      ),
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

  bool get _reactable => (widget.message.kind == 'text' || widget.message.kind == 'photo') && widget.message.seq != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final m = widget.message;
    final photo = _photo;
    final special = m.kind != 'text';
    final bubble = GestureDetector(
      onLongPress: _reactable ? _pick : null,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 480),
        padding: photo != null ? const EdgeInsets.fromLTRB(4, 4, 4, 6) : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: widget.mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(widget.mine ? 16 : 4),
            bottomRight: Radius.circular(widget.mine ? 4 : 16),
          ),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (widget.senderName != null)
            Padding(
              padding: photo != null ? const EdgeInsets.fromLTRB(8, 2, 8, 4) : EdgeInsets.zero,
              child: Text(widget.senderName!, style: theme.textTheme.labelMedium?.copyWith(color: scheme.primary)),
            ),
          if (photo != null)
            PhotoThumb(body: photo, messageId: m.id, onOpen: () => showPhotoViewer(context, photo))
          else
            Text(
              _text,
              style: special ? theme.textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic, color: scheme.onSurfaceVariant) : null,
            ),
          const SizedBox(height: 2),
          Row(mainAxisSize: MainAxisSize.min, children: [
            if (photo != null) const SizedBox(width: 8),
            Text(shortTime(DateTime.fromMillisecondsSinceEpoch(m.createdAt)), style: theme.textTheme.labelSmall),
            if (m.state == 'pending') ...[
              const SizedBox(width: 4),
              Icon(Icons.schedule, key: const Key('pending-icon'), size: 12, color: scheme.onSurfaceVariant, semanticLabel: 'Sending'),
            ],
          ]),
        ]),
      ),
    );
    final row = Row(
      mainAxisAlignment: widget.mine ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (widget.mine && hoverReactions) _hoverButton(),
        Flexible(child: bubble),
        if (!widget.mine && hoverReactions) _hoverButton(),
      ],
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Column(
          crossAxisAlignment: widget.mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            row,
            if (widget.reactions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Wrap(spacing: 4, children: [
                  for (final e in widget.reactions.entries)
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      backgroundColor: e.value.contains(widget.myUserId) ? scheme.secondaryContainer : null,
                      label: Text('${e.key} ${e.value.length}'),
                      onPressed: () => widget.onReact(e.value.contains(widget.myUserId) ? '' : e.key),
                    ),
                ]),
              ),
            if (m.state == 'failed')
              TextButton(
                onPressed: widget.onRetry,
                style: TextButton.styleFrom(foregroundColor: scheme.error, visualDensity: VisualDensity.compact),
                child: const Text('Not sent. Tap to retry'),
              ),
            if (widget.footer != null)
              Padding(
                padding: const EdgeInsets.only(top: 2, right: 4),
                child: Text(widget.footer!, style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _hoverButton() => AnimatedOpacity(
        opacity: _hover ? 1 : 0,
        duration: const Duration(milliseconds: 120),
        child: IconButton(
          tooltip: 'React',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add_reaction_outlined, size: 18),
          onPressed: _reactable ? _pick : null,
        ),
      );
}
