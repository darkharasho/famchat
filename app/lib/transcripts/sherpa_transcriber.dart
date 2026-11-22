// Whisper base through sherpa-onnx: the clip is decoded here (plugins need the main isolate), then
// split into speech segments by Silero VAD and transcribed in a background isolate.
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'model.dart';
import 'pcm.dart';
import 'transcriber.dart';

class SherpaTranscriber implements Transcriber {
  const SherpaTranscriber();

  @override
  Future<TranscriptResult> transcribe(String m4aPath, ModelPaths paths) async {
    final pcm = await decodeToPcm(m4aPath);
    final samples = pcm.sampleRate == 16000 ? pcm.samples : resampleLinear(pcm.samples, pcm.sampleRate, 16000);
    final (text, lang) = await Isolate.run(() => _run(samples, paths));
    return TranscriptResult(text, lang);
  }
}

/// [input] at [from] Hz as [to] Hz, by linear interpolation (speech, for Whisper: fine).
Float32List resampleLinear(Float32List input, int from, int to) {
  if (input.isEmpty || from == to) return input;
  final n = (input.length * to / from).floor();
  final out = Float32List(n);
  final step = from / to;
  for (var i = 0; i < n; i++) {
    final x = i * step;
    final j = x.floor();
    final f = x - j;
    final a = input[j];
    final b = j + 1 < input.length ? input[j + 1] : a;
    out[i] = a + (b - a) * f;
  }
  return out;
}

/// Where the Linux bundle keeps plugin libraries (next to the executable, in lib/); null elsewhere,
/// or when it isn't there (tests), so sherpa loads its library by name.
String? _sherpaLibDir() {
  if (!Platform.isLinux) return null;
  final dir = p.join(p.dirname(Platform.resolvedExecutable), 'lib');
  return File(p.join(dir, 'libsherpa-onnx-c-api.so')).existsSync() ? dir : null;
}

Future<(String, String?)> _run(Float32List samples, ModelPaths paths) async {
  await sherpa.initBindingsAsync(_sherpaLibDir());
  final vad = sherpa.VoiceActivityDetector(
    config: sherpa.VadModelConfig(
      sileroVad: sherpa.SileroVadModelConfig(
        model: paths.vad,
        threshold: 0.5,
        minSilenceDuration: 0.5,
        minSpeechDuration: 0.25,
        maxSpeechDuration: 20,
        windowSize: 512,
      ),
      sampleRate: 16000,
      numThreads: 1,
      debug: false,
    ),
    bufferSizeInSeconds: samples.length / 16000 + 10,
  );
  sherpa.OfflineRecognizer? recognizer;
  try {
    final segments = <Float32List>[];
    void drain() {
      while (!vad.isEmpty()) {
        segments.add(vad.front().samples);
        vad.pop();
      }
    }

    const window = 512;
    for (var i = 0; i + window <= samples.length; i += window) {
      vad.acceptWaveform(Float32List.sublistView(samples, i, i + window));
      drain();
    }
    vad.flush();
    drain();
    if (segments.isEmpty) return ('', null);

    recognizer = sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        whisper: sherpa.OfflineWhisperModelConfig(encoder: paths.encoder, decoder: paths.decoder, language: '', task: 'transcribe'),
        tokens: paths.tokens,
        numThreads: 2,
        debug: false,
      ),
    ));
    final texts = <String>[];
    String? lang;
    for (final s in segments) {
      final stream = recognizer.createStream();
      try {
        stream.acceptWaveform(samples: s, sampleRate: 16000);
        recognizer.decode(stream);
        final r = recognizer.getResult(stream);
        final t = r.text.trim();
        if (t.isNotEmpty) texts.add(t);
        if (lang == null && r.lang.isNotEmpty) lang = r.lang.replaceAll(RegExp(r'[<>|]'), '');
      } finally {
        stream.free();
      }
    }
    return (texts.join(' ').trim(), lang == null || lang.isEmpty ? null : lang);
  } finally {
    recognizer?.free();
    vad.free();
  }
}
