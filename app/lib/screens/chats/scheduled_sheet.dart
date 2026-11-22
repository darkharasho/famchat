// My scheduled messages in a chat (docs/protocol.md "Scheduled messages"): the "Scheduled (N)" bar
// above the composer and the list it opens, with Send now, Edit and Delete (Retry when one failed).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/db/chat_db.dart';
import '../../chat/message_changes.dart';
import '../../chat/providers.dart';
import '../../theme/tokens.dart';
import '../sign_out.dart' show apiErrorMessage;
import 'chat_list.dart' show messageSnippet;
import 'time_picker_sheet.dart';

/// [s] as a message row, for snippets.
MessageRow _asMessage(ScheduledRow s) => MessageRow(
      id: s.id,
      chatId: s.chatId,
      seq: null,
      senderUserId: '',
      senderDeviceId: s.senderDeviceId ?? '',
      kind: s.kind ?? 'unknown',
      body: s.body,
      targetId: null,
      envelope: null,
      createdAt: s.createdAt,
      state: 'pending',
    );

/// What the list shows for [s]'s content.
String scheduledSnippet(ScheduledRow s) {
  if (s.body == null) return 'Scheduled message';
  final m = _asMessage(s);
  final text = messageSnippet(m, messageChanges([m]));
  return text.trim().isEmpty ? 'Scheduled message' : text;
}

/// [s]'s state in words, or null while it simply waits for its time.
String? scheduledStateLabel(ScheduledRow s) => switch (s.state) {
      'local' => 'Waiting to upload',
      'needs_resend' => s.body == null ? "Can't be sent from this device" : 'Sending again',
      'failed' => s.onServer ? "Couldn't be sent" : "Couldn't be scheduled",
      _ => null,
    };

/// The bar above the composer while I have messages scheduled in [chatId]; nothing otherwise.
class ScheduledBar extends ConsumerWidget {
  const ScheduledBar({super.key, required this.chatId, this.mentionsOf});

  final String chatId;

  /// Who an edited text @mentions.
  final List<String> Function(String text)? mentionsOf;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(scheduledProvider(chatId)).value ?? const <ScheduledRow>[];
    if (list.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final failed = list.any((r) => r.state == 'failed');
    final next = list.first;
    return Material(
      color: s.surfaceContainer,
      child: InkWell(
        key: const Key('scheduled-bar'),
        onTap: () => showScheduledSheet(context, chatId, mentionsOf: mentionsOf),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.sm),
          child: Row(children: [
            Icon(failed ? Icons.error_outline_rounded : Icons.schedule_send_outlined,
                size: 20, color: failed ? s.error : s.tertiary),
            const SizedBox(width: Space.md),
            Text('Scheduled (${list.length})', style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(width: Space.md),
            Expanded(
              child: Text(
                'Next: ${whenLabel(DateTime.fromMillisecondsSinceEpoch(next.deliverAt), h24: MediaQuery.alwaysUse24HourFormatOf(context))}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant),
              ),
            ),
            Icon(Icons.expand_less_rounded, color: s.onSurfaceVariant),
          ]),
        ),
      ),
    );
  }
}

/// The list of my scheduled messages in [chatId].
Future<void> showScheduledSheet(BuildContext context, String chatId, {List<String> Function(String text)? mentionsOf}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _ScheduledSheet(chatId: chatId, mentionsOf: mentionsOf),
    );

class _ScheduledSheet extends ConsumerWidget {
  const _ScheduledSheet({required this.chatId, this.mentionsOf});

  final String chatId;
  final List<String> Function(String text)? mentionsOf;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final list = ref.watch(scheduledProvider(chatId)).value ?? const <ScheduledRow>[];
    final h24 = MediaQuery.alwaysUse24HourFormatOf(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: ListView(shrinkWrap: true, key: const Key('scheduled-sheet'), children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.xl, Space.lg, Space.xl, Space.xs),
            child: Text('Scheduled messages', style: theme.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.xl, 0, Space.xl, Space.sm),
            child: Text(
              'They go out at their time even if your devices are off. Only you see them until then.',
              style: theme.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant),
            ),
          ),
          if (list.isEmpty)
            const ListTile(title: Text('Nothing scheduled here.')),
          for (final r in list)
            ListTile(
              key: Key('scheduled-${r.id}'),
              leading: Icon(
                r.state == 'failed' ? Icons.error_outline_rounded : Icons.schedule_send_outlined,
                color: r.state == 'failed' ? s.error : s.tertiary,
              ),
              title: Text(scheduledSnippet(r), maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text([
                whenLabel(DateTime.fromMillisecondsSinceEpoch(r.deliverAt), h24: h24),
                ?scheduledStateLabel(r),
              ].join(' · ')),
              trailing: PopupMenuButton<String>(
                key: Key('scheduled-menu-${r.id}'),
                tooltip: 'Options',
                onSelected: (v) => unawaited(_act(context, ref, r, v)),
                itemBuilder: (context) => [
                  if (r.state == 'failed')
                    const PopupMenuItem(value: 'retry', child: ListTile(leading: Icon(Icons.refresh_rounded), title: Text('Retry')))
                  else
                    const PopupMenuItem(value: 'send', child: ListTile(leading: Icon(Icons.send_rounded), title: Text('Send now'))),
                  if (r.body != null)
                    const PopupMenuItem(value: 'edit', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Edit'))),
                  PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      leading: Icon(Icons.delete_outline_rounded, color: s.error),
                      title: Text('Delete', style: TextStyle(color: s.error)),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: Space.sm),
        ]),
      ),
    );
  }

  Future<void> _act(BuildContext context, WidgetRef ref, ScheduledRow r, String action) async {
    final sync = ref.read(chatSyncProvider);
    if (sync == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final h24 = MediaQuery.alwaysUse24HourFormatOf(context);
    void snack(String text) => messenger?.showSnackBar(SnackBar(content: Text(text)));
    try {
      switch (action) {
        case 'send':
          await sync.sendScheduledNow(r.id);
        case 'retry':
          await sync.retryScheduled(r.id);
        case 'delete':
          await sync.cancelScheduled(r.id);
        case 'edit':
          final edit = await _edit(context, r);
          if (edit == null || !context.mounted) return;
          final text = edit.text;
          await sync.editScheduled(
            r.id,
            text: text,
            mentions: text == null ? null : mentionsOf?.call(text),
            at: edit.at,
          );
          snack('Scheduled for ${whenLabel(edit.at ?? DateTime.fromMillisecondsSinceEpoch(r.deliverAt), h24: h24)}');
      }
    } on ArgumentError {
      snack(action == 'edit' ? "That can't be saved. Check the text and the time." : "Couldn't do that.");
    } on StateError {
      snack("That scheduled message can't be changed from this device.");
    } catch (e) {
      snack(apiErrorMessage(e));
    }
  }

  /// Asks for the new text (when it has one) and time; null when cancelled or nothing changed.
  Future<({String? text, DateTime? at})?> _edit(BuildContext context, ScheduledRow r) async {
    final m = _asMessage(r);
    final current = messageChanges([m]).textOf(m);
    if (m.kind != 'text' && !captionKinds.contains(m.kind)) {
      final at = await pickTime(context, title: 'Send at');
      return at == null ? null : (text: null, at: at);
    }
    return showDialog<({String? text, DateTime? at})>(
      context: context,
      builder: (context) => _EditDialog(text: current ?? '', at: DateTime.fromMillisecondsSinceEpoch(r.deliverAt), caption: m.kind != 'text'),
    );
  }
}

class _EditDialog extends StatefulWidget {
  const _EditDialog({required this.text, required this.at, required this.caption});

  final String text;
  final DateTime at;

  /// A photo's or video's caption (may be left empty) rather than a text.
  final bool caption;

  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  late final _text = TextEditingController(text: widget.text);
  DateTime? _at;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h24 = MediaQuery.alwaysUse24HourFormatOf(context);
    return AlertDialog(
      title: const Text('Edit scheduled message'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          key: const Key('scheduled-edit-text'),
          controller: _text,
          autofocus: true,
          minLines: 1,
          maxLines: 6,
          decoration: InputDecoration(hintText: widget.caption ? 'Caption' : 'Message'),
        ),
        const SizedBox(height: Space.md),
        Row(children: [
          const Icon(Icons.schedule_rounded, size: 18),
          const SizedBox(width: Space.sm),
          Expanded(child: Text(whenLabel(_at ?? widget.at, h24: h24))),
          TextButton(
            key: const Key('scheduled-edit-time'),
            onPressed: () async {
              final at = await pickTime(context, title: 'Send at');
              if (at != null && mounted) setState(() => _at = at);
            },
            child: const Text('Change'),
          ),
        ]),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const Key('scheduled-edit-save'),
          onPressed: () {
            final text = _text.text == widget.text ? null : _text.text;
            if (text == null && _at == null) return Navigator.pop(context);
            if (!widget.caption && text != null && text.trim().isEmpty) return;
            Navigator.pop(context, (text: text, at: _at));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
