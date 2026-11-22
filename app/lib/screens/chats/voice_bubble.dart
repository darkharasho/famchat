// A voice message inside a bubble: play/pause, a scrubbable waveform, the time, and the expired,
// failed and uploading states. Playback goes through the app-wide VoicePlayback (one clip at a time).
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/plaintext.dart';
import '../../media/media_service.dart';
import '../../media/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../voice/providers.dart';

/// "m:ss", rounded down.
String formatClock(Duration d) {
  final s = d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

const _waveWidth = 168.0, _waveHeight = 32.0;

class VoiceBubble extends ConsumerWidget {
  const VoiceBubble({super.key, required this.body, required this.messageId, this.mine = false, this.transcript});

  final VoiceBody body;
  final String messageId;

  /// In the sender's own (amber) bubble.
  final bool mine;

  /// The words of the clip, shown under it (the sender's, or one made on this device).
  final String? transcript;

  Duration get _length => Duration(milliseconds: body.durationMs);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final t = FamTokens.of(context);
    final ink = mine ? t.onMineBubble : t.onTheirsBubble;
    final meta = mine ? t.mineMeta : t.theirsMeta;
    // The play button: dusk on amber for your own clips, the theme's primary on everyone else's.
    final buttonBg = mine ? t.onMineBubble : scheme.primary;
    final buttonFg = mine ? t.mineBubble : scheme.onPrimary;
    final expired = (ref.watch(expiredMediaProvider).value ?? const <String>{}).contains(body.mediaKey);
    if (expired) {
      // The words outlast the audio.
      return _withTranscript(Row(key: const Key('voice-expired'), mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.mic_off_outlined, color: meta),
        const SizedBox(width: 8),
        Flexible(child: Text('Voice message expired', style: TextStyle(color: meta, fontStyle: FontStyle.italic))),
      ]), ink);
    }
    final state = ref.watch(voicePlaybackProvider.select((s) => s.messageId == messageId ? s : null));
    final progress = ref.watch(uploadProgressProvider(messageId)).value;
    final playback = ref.read(voicePlaybackProvider.notifier);
    Future<Uint8List?> load() {
      final media = ref.read(mediaServiceProvider);
      if (media == null) throw StateError('signed out');
      return media.load(body.ref);
    }

    final Widget button;
    if (state?.loading ?? false) {
      button = SizedBox.square(
        dimension: 40,
        child: Padding(padding: const EdgeInsets.all(10), child: CircularProgressIndicator(strokeWidth: 2, color: ink)),
      );
    } else {
      final failed = state?.error != null;
      final playing = state?.playing ?? false;
      button = IconButton.filled(
        tooltip: failed ? 'Retry voice message' : (playing ? 'Pause voice message' : 'Play voice message'),
        style: IconButton.styleFrom(backgroundColor: buttonBg, foregroundColor: buttonFg, fixedSize: const Size.square(40)),
        icon: Icon(failed ? Icons.refresh_rounded : (playing ? Icons.pause_rounded : Icons.play_arrow_rounded)),
        onPressed: () => playback.toggle(messageId, load, duration: _length),
      );
    }
    final position = state?.position ?? Duration.zero;
    final showPosition = state != null && (state.playing || position > Duration.zero);
    final player = Semantics(
      label: 'Voice message, ${formatClock(_length)}',
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Stack(alignment: Alignment.center, children: [
          button,
          if (progress != null && progress < 1)
            SizedBox.square(
              dimension: 40,
              child: CircularProgressIndicator(
                key: const Key('upload-progress'),
                strokeWidth: 2.5,
                color: buttonFg,
                value: progress == 0 ? null : progress,
              ),
            ),
        ]),
        const SizedBox(width: 10),
        GestureDetector(
          key: const Key('voice-waveform'),
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => playback.seek(messageId, d.localPosition.dx / _waveWidth, load, duration: _length),
          onHorizontalDragUpdate: (d) =>
              playback.seek(messageId, d.localPosition.dx / _waveWidth, load, duration: _length),
          child: CustomPaint(
            size: const Size(_waveWidth, _waveHeight),
            painter: WaveformPainter(
              peaks: body.waveform,
              progress: state?.progress ?? 0,
              played: ink,
              unplayed: ink.withValues(alpha: 0.32),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          formatClock(showPosition ? position : _length),
          key: const Key('voice-time'),
          style: Theme.of(context)
              .textTheme
              .labelMedium
              ?.copyWith(fontFamily: kDisplayFont, color: meta, fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      ]),
    );
    return _withTranscript(player, ink);
  }

  Widget _withTranscript(Widget player, Color ink) {
    final words = transcript;
    if (words == null) return player;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      player,
      const SizedBox(height: 6),
      SizedBox(width: _playerWidth, child: _Transcript(words, color: ink)),
    ]);
  }
}

/// About the player row's width: the transcript wraps to it.
const _playerWidth = 40.0 + 10 + _waveWidth + 8 + 40;

/// A transcript, three lines until tapped.
class _Transcript extends StatefulWidget {
  const _Transcript(this.text, {required this.color});
  final String text;
  final Color color;

  @override
  State<_Transcript> createState() => _TranscriptState();
}

class _TranscriptState extends State<_Transcript> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _expanded = !_expanded),
        child: Text(
          widget.text,
          key: const Key('voice-transcript'),
          maxLines: _expanded ? null : 3,
          overflow: _expanded ? null : TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: widget.color),
        ),
      );
}

/// Bars for [peaks] (0–255) scaled to the loudest one; the first [progress] of them in [played].
class WaveformPainter extends CustomPainter {
  WaveformPainter({required this.peaks, required this.progress, required this.played, required this.unplayed, this.bars = 42});

  final List<int> peaks;
  final double progress;
  final Color played, unplayed;
  final int bars;

  @override
  void paint(Canvas canvas, Size size) {
    final step = size.width / bars;
    final barWidth = (step * 0.6).clamp(1.5, 4.0);
    final loudest = peaks.isEmpty ? 0 : peaks.reduce((a, b) => a > b ? a : b);
    final paint = Paint()..strokeCap = StrokeCap.round;
    for (var i = 0; i < bars; i++) {
      final v = peaks.isEmpty || loudest == 0 ? 0.0 : peaks[i * peaks.length ~/ bars] / loudest;
      final h = (size.height * v).clamp(barWidth, size.height);
      final x = step * i + step / 2;
      paint
        ..color = (i + 0.5) / bars <= progress ? played : unplayed
        ..strokeWidth = barWidth;
      canvas.drawLine(Offset(x, (size.height - h) / 2 + barWidth / 2), Offset(x, (size.height + h) / 2 - barWidth / 2), paint);
    }
  }

  @override
  bool shouldRepaint(WaveformPainter old) =>
      old.progress != progress || old.peaks != peaks || old.played != played || old.unplayed != unplayed;
}
