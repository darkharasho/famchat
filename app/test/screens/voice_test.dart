import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:famchat/chat/chat_sync.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/chat/ulid.dart';
import 'package:famchat/crypto/media.dart';
import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:famchat/screens/chats/voice_bubble.dart';
import 'package:famchat/voice/waveform.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';
import '../support/fake_voice.dart';

final clip = Uint8List.fromList(List.generate(900, (i) => (i * 7) & 0xff));

void main() {
  late FakeChatBackend backend;
  late TestDevice alice, bob;
  late FakeRecorders recorders;
  late FakeVoicePlayer player;

  setUp(() async {
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    bob = await backend.addUser('Bob');
    recorders = FakeRecorders();
    player = FakeVoicePlayer();
  });

  void go(WidgetTester tester, String path) =>
      ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider).go(path);

  Future<(ScriptedHubLink, String)> open(WidgetTester tester) async {
    setWindow(tester, const Size(400, 800));
    final hub = await pumpChatApp(tester, alice, recorders: recorders, player: player);
    final chatId = await inApp(tester, () => ChatSync(db: alice.db, api: alice.api, hub: alice.hub, me: alice.me).openDirect(bob.userId));
    go(tester, '/chats/$chatId');
    await settle(tester);
    return (hub, chatId);
  }

  /// Pumps frames for [d] without waiting to settle (the recording timer keeps scheduling frames).
  Future<void> pumpFor(WidgetTester tester, Duration d) async {
    for (var t = Duration.zero; t < d; t += const Duration(milliseconds: 100)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Bob's voice message: the blob on the server, the message in Alice's database.
  Future<(VoiceBody, String)> bobsVoice(WidgetTester tester, String chatId) => inApp(tester, () async {
        final key = newMediaKey();
        final blob = await encryptMedia(key: key, plaintext: clip, purpose: MediaPurpose.file);
        final body = VoiceBody(
          mediaKey: newUlid(),
          key: key,
          sha256: await sha256Of(blob),
          durationMs: 4000,
          waveform: [for (var i = 0; i < 64; i++) (i * 4) & 0xff],
          bytes: clip.length,
        );
        await bob.media.upload(key: body.mediaKey, chatId: chatId, kind: 'voice', bytes: blob);
        final id = newUlid();
        await alice.db.insertMessageIfAbsent(MessageRow(
          id: id,
          chatId: chatId,
          seq: 1,
          senderUserId: bob.userId,
          senderDeviceId: bob.deviceId,
          kind: 'voice',
          body: jsonEncode(body.toJson()),
          targetId: null,
          envelope: null,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          state: 'sent',
        ));
        return (body, id);
      });

  chatTestWidgets('mic shows when the composer is empty and send when it has text', (tester) async {
    await open(tester);
    expect(find.byTooltip('Record voice message'), findsOneWidget);
    expect(find.byTooltip('Send'), findsNothing);
    await tester.enterText(find.byKey(const Key('composer')), 'hi');
    await tester.pump();
    expect(find.byTooltip('Record voice message'), findsNothing);
    expect(find.byTooltip('Send'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('composer')), '');
    await tester.pump();
    expect(find.byTooltip('Record voice message'), findsOneWidget);
  });

  chatTestWidgets("no mic where AAC recording isn't supported", (tester) async {
    recorders.supported = false;
    await open(tester);
    expect(find.byTooltip('Record voice message'), findsNothing);
    expect(find.byTooltip('Send'), findsOneWidget);
  });

  chatTestWidgets('recording shows the timer and sends a voice message', (tester) async {
    final (hub, chatId) = await open(tester);
    await tester.tap(find.byTooltip('Record voice message'));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('record-bar')), findsOneWidget);
    expect(find.byKey(const Key('composer')), findsNothing);
    expect(find.text('0:00'), findsOneWidget);
    for (var i = 0; i < 25; i++) {
      recorders.last.level(0.6);
      await tester.pump(levelInterval);
    }
    await pumpFor(tester, const Duration(milliseconds: 500));
    expect(find.text('0:03'), findsOneWidget);
    await tester.tap(find.byTooltip('Send voice message'));
    await settle(tester);
    expect(find.byKey(const Key('record-bar')), findsNothing);
    expect(find.byType(VoiceBubble), findsOneWidget);
    expect(find.byKey(const Key('pending-icon')), findsOneWidget);
    final row = (await inApp(tester, () => alice.db.pendingOutbox(alice.deviceId))).single;
    expect(row.kind, 'voice');
    final v = Plaintext.decode(utf8.encode(row.body!)) as VoiceBody;
    expect(v.durationMs, 3000);
    expect(v.waveform, hasLength(64));
    expect(v.bytes, recorders.last.output!.length);
    hub.setConnected(true);
    await settle(tester);
    expect(hub.sent.where((f) => f['type'] == 'send' && f['id'] == row.id), hasLength(1));
  });

  chatTestWidgets('discard sends nothing', (tester) async {
    final (_, chatId) = await open(tester);
    await tester.tap(find.byTooltip('Record voice message'));
    await pumpFor(tester, const Duration(seconds: 2));
    await tester.tap(find.byTooltip('Discard recording'));
    await settle(tester);
    expect(find.byKey(const Key('record-bar')), findsNothing);
    expect(find.byKey(const Key('composer')), findsOneWidget);
    expect(recorders.last.calls, containsAllInOrder(['cancel', 'dispose']));
    expect(await inApp(tester, () => alice.db.pendingOutbox(alice.deviceId)), isEmpty);
    expect(chatId, isNotEmpty);
  });

  chatTestWidgets('denied microphone explains and keeps the composer', (tester) async {
    recorders.granted = false;
    await open(tester);
    await tester.tap(find.byTooltip('Record voice message'));
    await settle(tester);
    expect(find.byKey(const Key('record-bar')), findsNothing);
    expect(find.textContaining('microphone'), findsOneWidget);
    expect(find.byKey(const Key('composer')), findsOneWidget);
  });

  chatTestWidgets('sending then leaving the chat at once still sends the clip', (tester) async {
    recorders.stopGate = Completer<void>();
    await open(tester);
    await tester.tap(find.byTooltip('Record voice message'));
    await pumpFor(tester, const Duration(seconds: 2));
    await tester.tap(find.byTooltip('Send voice message'));
    await tester.pump();
    go(tester, '/');
    await settle(tester);
    recorders.stopGate!.complete();
    await settle(tester);
    final out = await inApp(tester, () => alice.db.pendingOutbox(alice.deviceId));
    expect(out.single.kind, 'voice');
  });

  chatTestWidgets('a voice message that fails to send says so', (tester) async {
    recorders.made.clear();
    await open(tester);
    await tester.tap(find.byTooltip('Record voice message'));
    await pumpFor(tester, const Duration(seconds: 1));
    recorders.last.output = Uint8List(9 * 1024 * 1024); // over the 8 MiB voice cap
    await tester.tap(find.byTooltip('Send voice message'));
    await settle(tester);
    expect(find.text("That voice message can't be sent."), findsOneWidget);
  });

  chatTestWidgets('leaving the chat stops playback', (tester) async {
    final (_, chatId) = await open(tester);
    final (_, id) = await bobsVoice(tester, chatId);
    await settle(tester);
    await tester.tap(find.byTooltip('Play voice message'));
    await settle(tester);
    expect(player.isPlaying, isTrue);
    go(tester, '/');
    await settle(tester);
    await settle(tester); // the stop is queued after the frame that disposed the view
    expect(player.log.last, 'pause $id');
  });

  chatTestWidgets('leaving the chat while recording discards it', (tester) async {
    await open(tester);
    await tester.tap(find.byTooltip('Record voice message'));
    await pumpFor(tester, const Duration(seconds: 1));
    go(tester, '/');
    await settle(tester);
    expect(recorders.last.calls, containsAllInOrder(['cancel', 'dispose']));
  });

  chatTestWidgets('incoming voice plays and pauses', (tester) async {
    final (_, chatId) = await open(tester);
    final (body, id) = await bobsVoice(tester, chatId);
    await settle(tester);
    expect(find.byType(VoiceBubble), findsOneWidget);
    expect(find.text('0:04'), findsOneWidget);
    await tester.tap(find.byTooltip('Play voice message'));
    await settle(tester);
    expect(player.log, ['load $id', 'play $id']);
    expect(player.loaded[id], clip);
    expect(find.byTooltip('Pause voice message'), findsOneWidget);
    player.moveTo(const Duration(milliseconds: 1200));
    await settle(tester);
    expect(find.text('0:01'), findsOneWidget);
    await tester.tap(find.byTooltip('Pause voice message'));
    await settle(tester);
    expect(player.log.last, 'pause $id');
    expect(find.byTooltip('Play voice message'), findsOneWidget);
    expect(body.mediaKey, isNotEmpty);
  });

  chatTestWidgets('scrubbing seeks', (tester) async {
    final (_, chatId) = await open(tester);
    final (_, id) = await bobsVoice(tester, chatId);
    await settle(tester);
    final wave = tester.getRect(find.byKey(const Key('voice-waveform')));
    await tester.tapAt(Offset(wave.left + wave.width * 0.75, wave.center.dy));
    await settle(tester);
    expect(player.log, ['load $id', 'seek 3000']);
    expect(find.text('0:03'), findsOneWidget);
  });

  chatTestWidgets('expired voice shows Voice message expired', (tester) async {
    final (_, chatId) = await open(tester);
    final (body, _) = await bobsVoice(tester, chatId);
    await settle(tester);
    backend.expireMedia([body.mediaKey]); // Alice's hub is scripted: she learns via 410
    await tester.tap(find.byTooltip('Play voice message'));
    await settle(tester);
    expect(find.text('Voice message expired'), findsOneWidget);
    expect(find.byTooltip('Play voice message'), findsNothing);
    expect(player.log, isEmpty);
  });

  chatTestWidgets('a clip that fails to load offers a retry', (tester) async {
    final (_, chatId) = await open(tester);
    final (body, id) = await bobsVoice(tester, chatId);
    await settle(tester);
    backend.tamperMedia(body.mediaKey, Uint8List(64));
    await tester.tap(find.byTooltip('Play voice message'));
    await settle(tester);
    expect(find.byTooltip('Retry voice message'), findsOneWidget);
    expect(player.log, isEmpty);
    expect(id, isNotEmpty);
  });

  chatTestWidgets('voice messages can be reacted to', (tester) async {
    final (_, chatId) = await open(tester);
    final (_, id) = await bobsVoice(tester, chatId);
    await settle(tester);
    await tester.longPress(find.byType(VoiceBubble));
    await settle(tester);
    await tester.tap(find.text('👍'));
    await settle(tester);
    final reaction = (await inApp(tester, () => alice.db.pendingOutbox(alice.deviceId))).single;
    expect((reaction.kind, reaction.targetId), ('reaction', id));
    expect(find.text('👍 1'), findsOneWidget);
  });

  chatTestWidgets('chat list previews a voice message', (tester) async {
    final (_, chatId) = await open(tester);
    await bobsVoice(tester, chatId);
    go(tester, '/');
    await settle(tester);
    expect(find.text('🎤 Voice message'), findsOneWidget);
  });

  test('formatClock', () {
    expect(formatClock(Duration.zero), '0:00');
    expect(formatClock(const Duration(milliseconds: 4999)), '0:04');
    expect(formatClock(const Duration(minutes: 10)), '10:00');
  });
}
