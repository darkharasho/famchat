import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:famchat/chat/chat_sync.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/transcripts/model.dart';
import 'package:famchat/transcripts/transcriber.dart';
import 'package:famchat/transcripts/transcripts_service.dart';
import 'package:famchat/voice/waveform.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_chat_backend.dart';

const _paths = ModelPaths(encoder: 'e', decoder: 'd', tokens: 't', vad: 'v');

class _FakeTranscriber implements Transcriber {
  _FakeTranscriber(this.text, {this.before});
  final String text;
  Future<void> Function()? before;
  final seenFiles = <String>[];
  @override
  Future<TranscriptResult> transcribe(String m4aPath, ModelPaths paths) async {
    seenFiles.add(m4aPath);
    expect(File(m4aPath).existsSync(), isTrue);
    await before?.call();
    return TranscriptResult(text, 'en');
  }
}

RecordedVoice _clip(int seconds) =>
    RecordedVoice(bytes: Uint8List.fromList([1, 2, 3]), duration: Duration(seconds: seconds), waveform: const [1]);

VoiceBody _voice() => VoiceBody(
    mediaKey: 'mk', key: Uint8List(32), sha256: Uint8List(32), durationMs: 1000, waveform: const [1], bytes: 3);

void main() {
  late FakeChatBackend backend;
  late TestDevice alice, bob;
  late ChatSync aliceSync, bobSync;
  late String chatId;
  late Directory tmp;

  setUp(() async {
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    bob = await backend.addUser('Bob');
    aliceSync = ChatSync(db: alice.db, api: alice.api, hub: alice.hub, me: alice.me);
    bobSync = ChatSync(db: bob.db, api: bob.api, hub: bob.hub, me: bob.me);
    await aliceSync.start();
    await bobSync.start();
    chatId = await aliceSync.openDirect(bob.userId);
    tmp = await Directory.systemTemp.createTemp('transcripts_service_test');
  });
  tearDown(() async {
    await aliceSync.stop();
    await bobSync.stop();
    await alice.dispose();
    await bob.dispose();
    await tmp.delete(recursive: true);
  });

  TranscriptsService service(Transcriber t, {bool on = true, ModelState model = const ModelReady(_paths)}) =>
      TranscriptsService(sync: aliceSync, transcriber: t, model: () async => model, enabled: () async => on, tempDir: () async => tmp);

  Future<List<MessageRow>> transcripts(ChatDb db) async =>
      [for (final r in await db.watchMessages(chatId).first) if (r.kind == 'transcript') r];

  test('sends the transcript after an unscheduled short clip', () async {
    final id = await aliceSync.enqueueMessage(chatId, _voice());
    final fake = _FakeTranscriber('  pick up milk  ');
    await service(fake).afterVoiceSent(chatId, id, _clip(60), scheduled: false);
    final t = (await transcripts(alice.db)).single;
    expect(t.targetId, id);
    expect(jsonDecode(t.body!), {'kind': 'transcript', 'target': id, 'text': 'pick up milk', 'lang': 'en'});
    expect(File(fake.seenFiles.single).existsSync(), isFalse, reason: 'the temp clip is deleted');
  });

  test('nothing when off, not ready, scheduled, over 3 minutes, or silent', () async {
    final id = await aliceSync.enqueueMessage(chatId, _voice());
    await service(_FakeTranscriber('x'), on: false).afterVoiceSent(chatId, id, _clip(5), scheduled: false);
    await service(_FakeTranscriber('x'), model: const ModelAbsent()).afterVoiceSent(chatId, id, _clip(5), scheduled: false);
    await service(_FakeTranscriber('x')).afterVoiceSent(chatId, id, _clip(5), scheduled: true);
    await service(_FakeTranscriber('x')).afterVoiceSent(chatId, id, _clip(181), scheduled: false);
    await service(_FakeTranscriber('   ')).afterVoiceSent(chatId, id, _clip(5), scheduled: false);
    expect(await transcripts(alice.db), isEmpty);
  });

  test("sendTranscript trims, truncates to 20000, and skips others' or deleted clips", () async {
    final id = await aliceSync.enqueueMessage(chatId, _voice());
    final long = '${'a' * (maxTranscriptLength - 1)}😀 tail';
    expect(await aliceSync.sendTranscript(chatId, id, long), isNotNull);
    final body = jsonDecode((await transcripts(alice.db)).single.body!) as Map;
    expect((body['text'] as String).length, maxTranscriptLength - 1, reason: "the emoji isn't cut in half");

    final text = await aliceSync.enqueueMessage(chatId, const TextBody('hi'));
    expect(await aliceSync.sendTranscript(chatId, text, 'x'), isNull, reason: 'not a voice message');
    final bobs = await bobSync.enqueueMessage(chatId, _voice());
    await bobSync.idle;
    expect(await bobSync.sendTranscript(chatId, id, 'x'), isNull, reason: "Alice's clip");
    expect(await aliceSync.sendTranscript(chatId, bobs, 'x'), isNull, reason: "Bob's clip (not even here)");
    await aliceSync.deleteMessage(chatId, id);
    expect(await aliceSync.sendTranscript(chatId, id, 'again'), isNull, reason: 'deleted');
    expect(await aliceSync.sendTranscript(chatId, id, '   '), isNull);
  });

  test('a clip deleted while transcribing gets no transcript', () async {
    final id = await aliceSync.enqueueMessage(chatId, _voice());
    final fake = _FakeTranscriber('hello', before: () => aliceSync.deleteMessage(chatId, id));
    await service(fake).afterVoiceSent(chatId, id, _clip(5), scheduled: false);
    expect(await transcripts(alice.db), isEmpty);
  });

  test('marks the clip as transcribing while it runs', () async {
    final id = await aliceSync.enqueueMessage(chatId, _voice());
    final gate = Completer<void>();
    final s = service(_FakeTranscriber('hi', before: () => gate.future));
    final run = s.afterVoiceSent(chatId, id, _clip(5), scheduled: false);
    await until(() => s.transcribing.value.contains(id));
    gate.complete();
    await run;
    expect(s.transcribing.value, isEmpty);
  });
}

Future<void> until(bool Function() cond) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > const Duration(seconds: 5)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
