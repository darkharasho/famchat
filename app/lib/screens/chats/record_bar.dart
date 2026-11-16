// The composer while recording: a red dot, the elapsed time, live levels, discard and send.
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../voice/recording.dart';
import '../../voice/waveform.dart';
import 'voice_bubble.dart' show formatClock;

class RecordBar extends StatelessWidget {
  const RecordBar({super.key, required this.recording, required this.onDiscard, required this.onSend});

  final VoiceRecording recording;
  final VoidCallback onDiscard, onSend;

  /// Live bars shown (the most recent levels).
  static const liveBars = 36;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: recording,
      builder: (context, _) {
        final started = recording.status == RecordingStatus.recording;
        final elapsed = recording.elapsed;
        final levels = recording.levels;
        final recent = levels.sublist(math.max(0, levels.length - liveBars));
        return Row(key: const Key('record-bar'), children: [
          IconButton(tooltip: 'Discard recording', icon: const Icon(Icons.delete_outline), onPressed: onDiscard),
          Icon(Icons.fiber_manual_record, size: 14, color: started ? scheme.error : scheme.outline),
          const SizedBox(width: 6),
          Text(
            formatClock(elapsed),
            style: Theme.of(context).textTheme.titleSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
          if (maxVoiceDuration - elapsed <= const Duration(seconds: 30) && started)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text('of ${formatClock(maxVoiceDuration)}', style: Theme.of(context).textTheme.labelSmall),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: SizedBox(
              height: 32,
              child: CustomPaint(painter: _LivePainter(recent, scheme.primary, liveBars)),
            ),
          ),
          const SizedBox(width: 4),
          IconButton.filled(
            tooltip: 'Send voice message',
            icon: const Icon(Icons.send),
            onPressed: started ? onSend : null,
          ),
        ]);
      },
    );
  }
}

class _LivePainter extends CustomPainter {
  _LivePainter(this.levels, this.color, this.bars);
  final List<double> levels;
  final Color color;
  final int bars;

  @override
  void paint(Canvas canvas, Size size) {
    final step = size.width / bars;
    final w = (step * 0.6).clamp(1.5, 4.0);
    final paint = Paint()
      ..color = color
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round;
    // Newest on the right.
    for (var i = 0; i < levels.length; i++) {
      final x = size.width - step * (levels.length - i) + step / 2;
      final h = (size.height * levels[i].clamp(0.0, 1.0)).clamp(w, size.height);
      canvas.drawLine(Offset(x, (size.height - h) / 2 + w / 2), Offset(x, (size.height + h) / 2 - w / 2), paint);
    }
  }

  @override
  bool shouldRepaint(_LivePainter old) => true;
}
