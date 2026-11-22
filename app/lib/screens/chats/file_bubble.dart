// A file inside a bubble: its type icon, name, size and type. Tapping downloads and decrypts it,
// then opens it in the system's app for it (the web downloads it). Only documents, media and
// archives open with a tap (opensWithTap); anything else is only saved.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/files.dart';
import '../../chat/plaintext.dart';
import '../../media/file_actions.dart';
import '../../media/media_service.dart';
import '../../media/providers.dart';
import '../../theme/tokens.dart';

IconData fileIcon(FileCategory c) => switch (c) {
      FileCategory.pdf => Icons.picture_as_pdf_outlined,
      FileCategory.document => Icons.description_outlined,
      FileCategory.spreadsheet => Icons.table_chart_outlined,
      FileCategory.slides => Icons.slideshow_outlined,
      FileCategory.archive => Icons.folder_zip_outlined,
      FileCategory.audio => Icons.audio_file_outlined,
      FileCategory.code => Icons.code_rounded,
      FileCategory.image => Icons.image_outlined,
      FileCategory.video => Icons.video_file_outlined,
      FileCategory.generic => Icons.insert_drive_file_outlined,
    };

/// [name] cut to [max] characters in the middle, so the end and the extension stay:
/// "Quarterly report for the f…final.pdf".
String middleEllipsis(String name, {int max = 40}) {
  final chars = name.characters;
  if (chars.length <= max) return name;
  final ext = fileExtension(name);
  // The extension and a few characters before it.
  final tail = ext.isEmpty || ext.length > 8 ? 8 : ext.length + 1 + 6;
  final head = max - 1 - tail;
  return '${chars.take(head)}…${chars.skip(chars.length - tail)}';
}

/// Downloads and decrypts [body]; null when it expired.
Future<Uint8List?> loadFile(WidgetRef ref, FileBody body) {
  final media = ref.read(mediaServiceProvider);
  if (media == null) throw StateError('signed out');
  return media.load(body.ref);
}

/// "Save as…": a copy of [body] where the person picks (the web downloads it).
Future<void> saveFileMessage(BuildContext context, WidgetRef ref, FileBody body) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final actions = ref.read(fileActionsProvider);
  void say(String text) => messenger?.showSnackBar(SnackBar(content: Text(text)));
  try {
    final bytes = await loadFile(ref, body);
    if (bytes == null) return say('That file has expired.');
    if (await actions.save(name: body.name, mime: body.mime, bytes: bytes)) say('Saved');
  } catch (_) {
    say("Couldn't save that file.");
  }
}

class FileBubble extends ConsumerStatefulWidget {
  const FileBubble({super.key, required this.body, required this.messageId, this.mine = false});

  final FileBody body;
  final String messageId;

  /// In the sender's own (amber) bubble.
  final bool mine;

  @override
  ConsumerState<FileBubble> createState() => _FileBubbleState();
}

class _FileBubbleState extends ConsumerState<FileBubble> {
  bool _loading = false, _failed = false;

  void _say(String text, {SnackBarAction? action}) =>
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text), action: action));

  /// Not a type a tap opens: offer to save it instead.
  void _saveInstead() => _say(
        "FamChat only opens documents, photos, music and videos. Save this one, then open it yourself if you trust it.",
        action: SnackBarAction(label: 'Save', onPressed: () => saveFileMessage(context, ref, widget.body)),
      );

  Future<void> _open() async {
    if (_loading) return;
    final body = widget.body;
    if (!opensWithTap(diskFileName(body.name))) return _saveInstead();
    final actions = ref.read(fileActionsProvider);
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final bytes = await loadFile(ref, body);
      if (!mounted) return;
      if (bytes == null) return _say('That file has expired.');
      final outcome = await actions.open(id: widget.messageId, name: body.name, mime: body.mime, bytes: bytes);
      if (!mounted) return;
      if (outcome == OpenOutcome.noApp) _say('Nothing here can open "${body.name}". Save it instead.');
      if (outcome == OpenOutcome.failed) _say("Couldn't open that file.");
      if (outcome == OpenOutcome.notAllowed) _saveInstead();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = FamTokens.of(context);
    final body = widget.body;
    final ink = widget.mine ? t.onMineBubble : t.onTheirsBubble;
    final meta = widget.mine ? t.mineMeta : t.theirsMeta;
    final expired = (ref.watch(expiredMediaProvider).value ?? const <String>{}).contains(body.mediaKey);
    if (expired) {
      return Row(key: const Key('file-expired'), mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.insert_drive_file_outlined, color: meta),
        const SizedBox(width: 8),
        Flexible(child: Text('File expired', style: TextStyle(color: meta, fontStyle: FontStyle.italic))),
      ]);
    }
    final progress = ref.watch(uploadProgressProvider(widget.messageId)).value;
    final category = fileCategoryOf(body.name, body.mime);
    final size = formatBytes(body.bytes), type = fileTypeLabel(body.name);
    final Widget badge;
    if (_loading) {
      badge = Padding(
        key: const Key('file-loading'),
        padding: const EdgeInsets.all(12),
        child: CircularProgressIndicator(strokeWidth: 2, color: ink),
      );
    } else if (_failed) {
      badge = Icon(Icons.refresh_rounded, key: const Key('file-retry'), color: ink);
    } else {
      badge = Icon(fileIcon(category), key: Key('file-icon-${category.name}'), color: ink);
    }
    return Semantics(
      button: true,
      label: '${_failed ? "Couldn't download. Retry: " : ''}File ${body.name}, $size',
      excludeSemantics: true,
      child: InkWell(
        key: Key('file-${widget.messageId}'),
        borderRadius: BorderRadius.circular(Radii.sm),
        onTap: _open,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 200, maxWidth: 300),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Stack(alignment: Alignment.center, children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: ink.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(Radii.sm)),
                alignment: Alignment.center,
                child: badge,
              ),
              if (progress != null && progress < 1)
                SizedBox.square(
                  dimension: 40,
                  child: CircularProgressIndicator(
                    key: const Key('upload-progress'),
                    strokeWidth: 2.5,
                    color: ink,
                    value: progress == 0 ? null : progress,
                  ),
                ),
            ]),
            const SizedBox(width: 10),
            Flexible(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(
                  middleEllipsis(body.name),
                  key: const Key('file-name'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(color: ink, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  _failed ? "Couldn't download. Tap to retry" : '$size · $type',
                  key: const Key('file-meta'),
                  style: theme.textTheme.labelSmall?.copyWith(color: meta),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
