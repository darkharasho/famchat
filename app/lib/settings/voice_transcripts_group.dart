// The Settings page's "Voice transcripts" group: the switch, the model download's progress, and
// Remove model. Not on the web (no model there).
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../transcripts/model.dart';
import '../widgets/common.dart';
import 'voice_transcripts.dart';

String _mb(int bytes) => '${(bytes / 1e6).round()} MB';

class VoiceTranscriptsGroup extends ConsumerWidget {
  const VoiceTranscriptsGroup({super.key, this.onWeb = kIsWeb});

  /// For tests.
  final bool onWeb;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (onWeb) return const SizedBox.shrink();
    final on = ref.watch(voiceTranscriptsProvider).value ?? false;
    final model = ref.watch(transcriptModelProvider);
    final notifier = ref.read(transcriptModelProvider.notifier);
    final theme = Theme.of(context);
    final Widget subtitle = switch (model) {
      ModelDownloading(:final received, :final total) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 4),
          LinearProgressIndicator(key: const Key('transcripts-progress'), value: total == 0 ? null : received / total),
          const SizedBox(height: 4),
          Text('Downloading… ${_mb(received)} of ${_mb(total)}'),
        ]),
      ModelFailed(:final message) => Text(message, style: TextStyle(color: theme.colorScheme.error)),
      ModelReady() => const Text('Your voice messages get a written transcript.'),
      ModelAbsent() || ModelChecking() =>
        Text('Downloads a ${_mb(modelDownloadBytes)} speech model. Audio never leaves this device.'),
    };
    return SettingsGroup(title: 'Voice transcripts', children: [
      SwitchListTile(
        key: const Key('settings-voice-transcripts'),
        secondary: const TileIcon(Icons.subtitles_outlined),
        title: const Text('Transcribe my voice messages'),
        subtitle: subtitle,
        isThreeLine: model is ModelDownloading,
        value: on,
        onChanged: (v) async {
          await ref.read(voiceTranscriptsProvider.notifier).set(v);
          if (v && model is! ModelReady) await notifier.download();
        },
      ),
      if (model is ModelDownloading)
        ListTile(
          key: const Key('transcripts-cancel'),
          leading: const TileIcon(Icons.close_rounded),
          title: const Text('Cancel download'),
          onTap: notifier.cancel,
        ),
      if (model is ModelFailed)
        ListTile(
          key: const Key('transcripts-retry'),
          leading: const TileIcon(Icons.refresh_rounded),
          title: const Text('Try again'),
          onTap: notifier.download,
        ),
      if (model is ModelReady)
        ListTile(
          key: const Key('transcripts-remove'),
          leading: const TileIcon(Icons.delete_outline_rounded),
          title: const Text('Remove model'),
          subtitle: Text('Frees ${_mb(modelDownloadBytes)}. Turn transcripts on again to download it.'),
          onTap: () async {
            final yes = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Remove the speech model?'),
                content: const Text("New voice messages won't get transcripts until you download it again."),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                  TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
                ],
              ),
            );
            if (yes == true) await notifier.remove();
          },
        ),
    ]);
  }
}
