// The Whisper model for on-device voice transcripts: downloaded once when asked for (about 160 MB),
// pinned to a Hugging Face commit and checked file by file. The Silero VAD model is bundled.
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The `csukuangfj/sherpa-onnx-whisper-base` commit the files are pinned to.
const whisperCommit = 'bb53ee204431c90d314c1cc08d28d23e5b7927cc';
const whisperBaseUrl = 'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-base/resolve/$whisperCommit';
const vadAsset = 'assets/models/silero_vad.onnx';

class ModelFile {
  const ModelFile(this.name, this.size, this.sha256);
  final String name;
  final int size;

  /// Lowercase hex.
  final String sha256;
}

const whisperFiles = [
  ModelFile('base-encoder.int8.onnx', 29120534, '0b8fb1304b6109976038efff5ace81720e00386f3ff6b54ee8c75291ca0a1e11'),
  ModelFile('base-decoder.int8.onnx', 130672026, '9759d217388a01b3a4c7c15533201067b48ae819c4daafc8624e64b9409dc02d'),
  ModelFile('base-tokens.txt', 816730, 'b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126'),
];

/// What the download costs, for the settings copy.
const modelDownloadBytes = 29120534 + 130672026 + 816730;

class ModelPaths {
  const ModelPaths({required this.encoder, required this.decoder, required this.tokens, required this.vad});
  final String encoder, decoder, tokens, vad;
}

sealed class ModelState {
  const ModelState();
}

/// Still looking at what's on disk.
class ModelChecking extends ModelState {
  const ModelChecking();
}

class ModelAbsent extends ModelState {
  const ModelAbsent();
}

class ModelDownloading extends ModelState {
  const ModelDownloading(this.received, this.total);
  final int received, total;
}

class ModelReady extends ModelState {
  const ModelReady(this.paths);
  final ModelPaths paths;
}

class ModelFailed extends ModelState {
  const ModelFailed(this.message);
  final String message;
}

/// Test seams.
final modelFilesProvider = Provider<List<ModelFile>>((ref) => whisperFiles);
final modelBaseUrlProvider = Provider<String>((ref) => whisperBaseUrl);
final modelDirProvider = Provider<Future<Directory> Function()>((ref) => () async =>
    Directory(p.join((await getApplicationSupportDirectory()).path, 'transcripts', 'whisper-base-${whisperCommit.substring(0, 7)}')));
final modelHttpClientProvider = Provider<http.Client>((ref) {
  final c = http.Client();
  ref.onDispose(c.close);
  return c;
});
final vadBytesProvider = Provider<Future<List<int>> Function()>(
    (ref) => () async => (await rootBundle.load(vadAsset)).buffer.asUint8List());

class _Cancelled implements Exception {
  const _Cancelled();
}

class TranscriptModel extends Notifier<ModelState> {
  int _run = 0; // bumped by cancel and remove, so a running download stops
  StreamSubscription<List<int>>? _body;
  Completer<void>? _wait; // the current file's download

  @override
  ModelState build() {
    unawaited(Future.microtask(refresh));
    return const ModelChecking();
  }

  Future<Directory> get _dir => ref.read(modelDirProvider)();

  /// Looks at what's on disk: ready only when every file is there with its size (hashes are
  /// checked when downloading, not on every start).
  Future<void> refresh() async {
    if (!ref.mounted || state is ModelDownloading) return;
    ModelPaths? paths;
    try {
      paths = await _readyPaths();
    } catch (_) {
      paths = null; // no app storage (tests), or unreadable: treat as not downloaded
    }
    if (!ref.mounted || state is ModelDownloading) return;
    state = paths == null ? const ModelAbsent() : ModelReady(paths);
  }

  /// Sets the state unless this download was cancelled meanwhile (or the notifier is gone).
  void _set(int run, ModelState s) {
    if (ref.mounted && run == _run) state = s;
  }

  Future<ModelPaths?> _readyPaths() async {
    final dir = await _dir;
    final files = ref.read(modelFilesProvider);
    for (final f in files) {
      final file = File(p.join(dir.path, f.name));
      if (!await file.exists() || await file.length() != f.size) return null;
    }
    // The VAD ships with the app; it's copied out (sherpa reads files), whole or not at all.
    final vad = File(p.join(dir.path, 'silero_vad.onnx'));
    final vadBytes = await ref.read(vadBytesProvider)();
    if (!await vad.exists() || await vad.length() != vadBytes.length) {
      final tmp = File('${vad.path}.tmp');
      await tmp.writeAsBytes(vadBytes, flush: true);
      await tmp.rename(vad.path);
    }
    String path(String suffix) => p.join(dir.path, files.firstWhere((f) => f.name.endsWith(suffix)).name);
    return ModelPaths(encoder: path('encoder.int8.onnx'), decoder: path('decoder.int8.onnx'), tokens: path('tokens.txt'), vad: vad.path);
  }

  /// Downloads whatever isn't there yet, checking each file's SHA-256.
  Future<void> download() async {
    if (state is ModelDownloading || state is ModelReady) return;
    final run = ++_run;
    final files = ref.read(modelFilesProvider);
    final total = files.fold<int>(0, (s, f) => s + f.size);
    _set(run, ModelDownloading(0, total));
    var received = 0;
    File? part;
    try {
      final dir = await _dir;
      await dir.create(recursive: true);
      // Leftovers of a run the app was killed in (a cancelled run deletes its own).
      await for (final e in dir.list()) {
        if (e is File && e.path.endsWith('.part') && !e.path.endsWith('.$run.part')) {
          try {
            await e.delete();
          } on FileSystemException {
            // Another run's, just renamed or deleted.
          }
        }
      }
      for (final f in files) {
        final dest = File(p.join(dir.path, f.name));
        if (await dest.exists() && await dest.length() == f.size) {
          received += f.size;
          continue;
        }
        part = File('${dest.path}.$run.part');
        final ok = await _fetch(f, part, run, (n) {
          received += n;
          _set(run, ModelDownloading(received, total));
        });
        if (!ok) {
          await _deletePart(part);
          _set(run, const ModelFailed('The download was damaged. Try again.'));
          return;
        }
        await part.rename(dest.path);
        part = null;
      }
      final paths = await _readyPaths();
      _set(run, paths == null ? const ModelFailed('The download was damaged. Try again.') : ModelReady(paths));
    } on _Cancelled {
      await _deletePart(part);
    } catch (_) {
      await _deletePart(part);
      _set(run, const ModelFailed("Couldn't download the speech model. Check your connection and try again."));
    }
  }

  /// Streams [f] into [part]; false when its size or hash is wrong.
  Future<bool> _fetch(ModelFile f, File part, int run, void Function(int) progress) async {
    final res = await ref.read(modelHttpClientProvider).send(http.Request('GET', Uri.parse('${ref.read(modelBaseUrlProvider)}/${f.name}')));
    if (run != _run || res.statusCode != 200) {
      // Close the connection: nothing will read this body.
      unawaited(res.stream.listen(null).cancel());
      if (run != _run) throw const _Cancelled();
      throw HttpException('HTTP ${res.statusCode}');
    }
    final sink = part.openWrite();
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    var size = 0;
    final done = _wait = Completer<void>();
    _body = res.stream.listen(
      (chunk) {
        sink.add(chunk);
        hasher.add(chunk);
        size += chunk.length;
        progress(chunk.length);
      },
      onError: (Object e) => done.isCompleted ? null : done.completeError(e),
      onDone: () => done.isCompleted ? null : done.complete(),
      cancelOnError: true,
    );
    try {
      await done.future;
    } finally {
      _body = null;
      _wait = null;
      await sink.close();
    }
    if (run != _run) throw const _Cancelled();
    hasher.close();
    return size == f.size && digest.value.toString() == f.sha256;
  }

  Future<void> _deletePart(File? part) async {
    try {
      if (part != null && await part.exists()) await part.delete();
    } on FileSystemException {
      // Already gone (removed meanwhile).
    }
  }

  /// Stops a download and deletes what it fetched of the current file.
  void cancel() {
    if (state is! ModelDownloading) return;
    _run++;
    state = const ModelAbsent();
    // A cancelled body never finishes its stream, so end the download's wait here; it then
    // deletes the partial file.
    unawaited(_body?.cancel());
    final wait = _wait;
    if (wait != null && !wait.isCompleted) wait.completeError(const _Cancelled());
  }

  /// Deletes the model to free the space.
  Future<void> remove() async {
    cancel();
    _run++;
    final dir = await _dir;
    if (await dir.exists()) await dir.delete(recursive: true);
    if (ref.mounted) state = const ModelAbsent();
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

final transcriptModelProvider = NotifierProvider<TranscriptModel, ModelState>(TranscriptModel.new);
