import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:material_ui/material_ui.dart';

import '../spikes/audio_spike.dart';
import '../spikes/crypto_spike.dart';
import '../spikes/db_spike.dart';
import '../spikes/ws_spike.dart';

/// Runs each platform spike and shows one result line per spike.
class SpikesScreen extends StatefulWidget {
  const SpikesScreen({super.key});

  @override
  State<SpikesScreen> createState() => _SpikesScreenState();
}

class _SpikesScreenState extends State<SpikesScreen> {
  final _results = <String, String>{};
  bool _busy = false;

  Future<void> _run(String name, Future<Object?> Function() spike) async {
    setState(() => _results[name] = 'running…');
    String line;
    try {
      line = 'ok: ${await spike()}';
    } catch (e) {
      line = 'FAILED: $e';
    }
    if (mounted) setState(() => _results[name] = line);
  }

  Future<void> _guard(Future<void> Function() body) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await body();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runAll() => _guard(() async {
        await _run('crypto', _cryptoSpike);
        await _run('database', () => dbRoundTrip('spike_screen'));
        await _run('websocket', () => wsEchoRoundTrip(echoUrl()));
        await _run('audio playback', playFixture);
        await _run('recorder', probeRecorder);
      });

  Future<void> _record() => _guard(() => _run('record 3 s and play', () async {
        final d = await recordAndPlay(const Duration(seconds: 3));
        return 'played ${d?.inMilliseconds} ms';
      }));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Platform spikes')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(spacing: 12, runSpacing: 12, children: [
            FilledButton(onPressed: _busy ? null : _runAll, child: const Text('Run all')),
            OutlinedButton(onPressed: _busy ? null : _record, child: const Text('Record 3 s and play')),
          ]),
          const SizedBox(height: 16),
          for (final e in _results.entries)
            ListTile(title: Text(e.key), subtitle: SelectableText(e.value)),
        ],
      ),
    );
  }
}

Future<String> _cryptoSpike() async {
  final identity = await Ed25519().newKeyPair();
  final enc = await X25519().newKeyPair();
  final sign = await Ed25519().newKeyPair();
  await makeDeviceCert(identity: identity, enc: enc, sign: sign);
  final sealed = await sealBox((await enc.extractPublicKey()).bytes, utf8.encode('k'));
  await openBox(enc, sealed);
  final signPub = (await sign.extractPublicKey()).bytes;
  final key = List.generate(32, (i) => i);
  final body = List.filled(1024, 7);
  final sw = Stopwatch()..start();
  for (var i = 0; i < 100; i++) {
    final env = await encryptEnvelope(
        chatKey: key, epoch: 1, chatId: 'C', messageId: 'M$i', senderDeviceId: 'D', signKey: sign, plaintext: body);
    await decryptEnvelope(
        chatKey: key, chatId: 'C', messageId: 'M$i', senderDeviceId: 'D', senderSignPub: signPub, envelope: env);
  }
  return '100 envelopes in ${sw.elapsedMilliseconds} ms';
}
