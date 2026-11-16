// Voice clip limits and the waveform that travels inside a voice message.
import 'dart:typed_data';

/// The longest voice message (spec: "Media storage cap"). The recorder stops itself here.
const maxVoiceDuration = Duration(minutes: 10);

/// Peaks per waveform sent with a voice message.
const waveformBuckets = 64;

/// How often the recorder reports its level while recording.
const levelInterval = Duration(milliseconds: 100);

/// A recorder level in dBFS mapped to 0..1 (−60 dB and below is silence).
double levelFromDb(double dbfs) {
  if (dbfs.isNaN) return 0;
  return ((dbfs + 60) / 60).clamp(0.0, 1.0);
}

/// [levels] (0..1, one per [levelInterval]) reduced to [buckets] peaks in 0..255. Empty input gives
/// an empty waveform; fewer samples than buckets repeat the nearest sample.
List<int> downsampleWaveform(List<double> levels, {int buckets = waveformBuckets}) {
  final n = levels.length;
  if (n == 0) return const [];
  int scale(double v) => v.isNaN ? 0 : (v.clamp(0.0, 1.0) * 255).round();
  return [
    for (var i = 0; i < buckets; i++)
      () {
        final start = i * n ~/ buckets;
        final end = ((i + 1) * n ~/ buckets).clamp(start + 1, n);
        var peak = 0;
        for (var j = start; j < end; j++) {
          final v = scale(levels[j]);
          if (v > peak) peak = v;
        }
        return peak;
      }(),
  ];
}

/// A finished recording, ready to send.
class RecordedVoice {
  const RecordedVoice({required this.bytes, required this.duration, required this.waveform});

  /// The AAC-LC `.m4a` file.
  final Uint8List bytes;
  final Duration duration;

  /// [waveformBuckets] peaks, 0–255.
  final List<int> waveform;
}
