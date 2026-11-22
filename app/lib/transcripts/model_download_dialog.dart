// Transcribe on a device without the speech model: offer the download (the same one Settings
// starts), then wait for it.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'model.dart';

/// True once the model is ready: at once if it is, else after the person agrees to download it
/// and the download finishes. False if they decline, cancel, or it fails.
Future<bool> ensureTranscriptModel(BuildContext context, WidgetRef ref) async {
  await ref.read(transcriptModelProvider.notifier).refresh();
  if (ref.read(transcriptModelProvider) is ModelReady) return true;
  if (!context.mounted) return false;
  // Already downloading (from Settings): just wait for it.
  final already = ref.read(transcriptModelProvider) is ModelDownloading;
  final mb = (modelDownloadBytes / 1e6).round();
  final yes = already || await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Download the speech model?'),
      content: Text('Transcribing needs a $mb MB speech model, downloaded once. Audio never leaves this device.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Download')),
      ],
    ),
      ) ==
      true;
  if (!yes || !context.mounted) return false;
  final n = ref.read(transcriptModelProvider.notifier);
  if (ref.read(transcriptModelProvider) is! ModelDownloading) {
    // ignore: discarded_futures
    n.download();
  }
  final ok = await showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => const _Downloading());
  return ok == true;
}

class _Downloading extends ConsumerStatefulWidget {
  const _Downloading();

  @override
  ConsumerState<_Downloading> createState() => _DownloadingState();
}

class _DownloadingState extends ConsumerState<_Downloading> {
  var _closed = false;

  void _close(bool ready) {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.pop(context, ready);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(transcriptModelProvider, (_, s) {
      if (s is ModelReady) _close(true);
      if (s is ModelAbsent) _close(false);
    });
    final s = ref.watch(transcriptModelProvider);
    // Finished before this showed.
    if (s is ModelReady) WidgetsBinding.instance.addPostFrameCallback((_) => _close(true));
    String mb(int b) => '${(b / 1e6).round()} MB';
    return AlertDialog(
      key: const Key('transcripts-download-dialog'),
      title: const Text('Downloading the speech model'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (s case ModelDownloading(:final received, :final total)) ...[
          LinearProgressIndicator(value: total == 0 ? null : received / total),
          const SizedBox(height: 8),
          Text('${mb(received)} of ${mb(total)}'),
        ] else if (s case ModelFailed(:final message))
          Text(message)
        else
          const LinearProgressIndicator(),
      ]),
      actions: [
        if (s is ModelFailed) ...[
          TextButton(onPressed: () => _close(false), child: const Text('Close')),
          TextButton(onPressed: ref.read(transcriptModelProvider.notifier).download, child: const Text('Try again')),
        ] else
          TextButton(onPressed: ref.read(transcriptModelProvider.notifier).cancel, child: const Text('Cancel')),
      ],
    );
  }
}
