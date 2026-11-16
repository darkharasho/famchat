// Renders the screenshots in docs/screenshots/ from the real widgets with the bundled fonts.
// Lives outside test/ so CI's `flutter test` skips it (fonts and emoji differ by machine).
//
//   cd app && flutter test test_screenshots --update-goldens
//
// Needs a color emoji font at /usr/share/fonts/twemoji/Twemoji.ttf (else emoji draw as boxes).
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/directory.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/chat/providers.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/dev_tools.dart';
import 'package:famchat/media/providers.dart';
import 'package:famchat/router.dart';
import 'package:famchat/session/secure_kv.dart';
import 'package:famchat/session/session_controller.dart';
import 'package:famchat/theme/app_theme.dart';
import 'package:famchat/voice/providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/support/chat_harness.dart' show ScriptedHubLink, settle, inApp;
import '../test/support/fake_chat_backend.dart';
import '../test/support/fake_media.dart';
import '../test/support/fake_server.dart';
import '../test/support/fake_voice.dart';
import '../test/support/session_overrides.dart';

const _emojiFamily = 'ScreenshotEmoji';

Future<void> _loadFonts() async {
  Future<void> family(String name, List<Future<ByteData>> faces) async {
    final loader = FontLoader(name);
    for (final f in faces) {
      loader.addFont(f);
    }
    await loader.load();
  }

  Future<ByteData> file(String path) async => ByteData.sublistView(await File(path).readAsBytes());
  await family('FamiljenGrotesk', [
    for (final w in ['Medium', 'SemiBold', 'Bold']) rootBundle.load('assets/fonts/FamiljenGrotesk-$w.ttf'),
  ]);
  await family('AtkinsonHyperlegibleNext', [
    for (final w in ['Regular', 'Italic', 'Medium', 'Bold']) rootBundle.load('assets/fonts/AtkinsonHyperlegibleNext-$w.ttf'),
  ]);
  final root = Platform.environment['FLUTTER_ROOT']!;
  await family('MaterialIcons', [file('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')]);
  const emoji = '/usr/share/fonts/twemoji/Twemoji.ttf';
  if (File(emoji).existsSync()) {
    await family(_emojiFamily, [file(emoji)]);
    // The emoji picker's grid asks for this family by name.
    await family('Noto Color Emoji', [file(emoji)]);
  }
}

ThemeData _withEmoji(ThemeData t) => t.copyWith(
      textTheme: t.textTheme.apply(fontFamilyFallback: const [_emojiFamily]),
    );

/// A dusk-to-amber "photo" of hills at sunset, so the photo bubble has something to show.
Uint8List _sunset() {
  const w = 640, h = 480;
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    final t = y / h;
    final r = (46 + (255 - 46) * t).round(), g = (37 + (170 - 37) * t * t).round(), b = (80 + (90 - 80) * t).round();
    for (var x = 0; x < w; x++) {
      image.setPixelRgb(x, y, r, g, b);
    }
  }
  img.fillCircle(image, x: 420, y: 330, radius: 70, color: img.ColorRgb8(255, 214, 120));
  for (var x = 0; x < w; x++) {
    final hill = (360 + 40 * math.sin(x / 90) + 20 * math.sin(x / 37)).round();
    for (var y = hill; y < h; y++) {
      image.setPixelRgb(x, y, 38, 30, 62);
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

ChatDto _dto(String id, String kind, List<String> members, {String? title, int lastSeq = 0, Map<String, int> read = const {}}) =>
    ChatDto(
      id: id,
      kind: kind,
      title: title,
      createdBy: members.first,
      currentEpoch: 1,
      epochReady: true,
      lastSeq: lastSeq,
      lastMessageAt: 1,
      createdAt: 1,
      members: [for (final m in members) MemberDto(userId: m, joinedSeq: 0, lastReadSeq: read[m] ?? lastSeq)],
    );

class _Family {
  late FakeChatBackend backend;
  late TestDevice mom, dad, gran, sam, lily, joe;

  Future<void> create() async {
    backend = FakeChatBackend();
    mom = await backend.addUser('Mom');
    dad = await backend.addUser('Dad');
    gran = await backend.addUser('Grandma Rose');
    sam = await backend.addUser('Sam');
    lily = await backend.addUser('Lily');
    joe = await backend.addUser('Uncle Joe');
  }
}

MessageRow _row(String id, String chat, int seq, String from, DateTime at, {String kind = 'text', String? body, String? target, String state = 'sent'}) =>
    MessageRow(
      id: id,
      chatId: chat,
      seq: seq,
      senderUserId: from,
      senderDeviceId: 'D',
      kind: kind,
      body: body,
      targetId: target,
      envelope: null,
      createdAt: at.millisecondsSinceEpoch,
      state: state,
    );

String _text(String t) => jsonEncode({'kind': 'text', 'text': t});
String _react(String e) => jsonEncode({'kind': 'reaction', 'emoji': e});

Future<void> _seed(_Family f) async {
  final db = f.mom.db;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  DateTime y(int h, int m) => today.subtract(const Duration(days: 1)).add(Duration(hours: h, minutes: m));
  DateTime t(int h, int m) => today.add(Duration(hours: h, minutes: m));
  final everyone = [f.mom.userId, f.dad.userId, f.gran.userId, f.sam.userId, f.lily.userId];

  await db.bindDevice(f.mom.deviceId);
  await db.upsertChat(_dto('sunday', 'group', everyone, title: 'Sunday dinner', lastSeq: 10));
  await db.upsertChat(_dto('gran', 'direct', [f.mom.userId, f.gran.userId], lastSeq: 3, read: {f.mom.userId: 1}));
  await db.upsertChat(_dto('sam', 'direct', [f.mom.userId, f.sam.userId], lastSeq: 2));
  await db.upsertChat(_dto('cousins', 'group', [f.mom.userId, f.sam.userId, f.lily.userId, f.joe.userId], title: 'Cousins', lastSeq: 5, read: {f.mom.userId: 3}));
  await db.upsertChat(_dto('dad', 'direct', [f.mom.userId, f.dad.userId], lastSeq: 1));

  final photo = PhotoBody(
    mediaKey: '01JC00000000000000000PH0T0',
    thumbKey: '01JC00000000000000000THVMB',
    key: Uint8List(32),
    sha256: Uint8List(32),
    thumbSha256: Uint8List(32),
    width: 640,
    height: 480,
    bytes: 1,
  );
  final voice = VoiceBody(
    mediaKey: '01JC00000000000000000V01CE',
    key: Uint8List(32),
    sha256: Uint8List(32),
    durationMs: 14000,
    waveform: [for (var i = 0; i < 64; i++) (128 + 110 * math.sin(i / 3) * math.cos(i / 7)).round().clamp(10, 255)],
    bytes: 1,
  );
  final rows = [
    _row('s1', 'sunday', 1, f.gran.userId, y(18, 2), body: _text("Who's bringing dessert on Sunday?")),
    _row('s2', 'sunday', 2, f.dad.userId, y(18, 5), body: _text("I'll make the lemon cake")),
    _row('s3', 'sunday', 3, f.dad.userId, y(18, 6), body: _text('Unless someone else wants to 🍋')),
    _row('s4', 'sunday', 4, f.mom.userId, y(18, 20), body: _text('Lemon cake, yes please!')),
    _row('s5', 'sunday', 5, f.sam.userId, t(9, 12), kind: 'photo', body: jsonEncode(photo.toJson())),
    _row('s6', 'sunday', 6, f.sam.userId, t(9, 12), body: _text('View from the train this morning')),
    _row('s7', 'sunday', 7, f.lily.userId, t(9, 30), kind: 'voice', body: jsonEncode(voice.toJson())),
    _row('s8', 'sunday', 8, f.gran.userId, t(9, 41), body: _text('Beautiful! Safe travels, love')),
    _row('r1', 'sunday', 9, f.mom.userId, t(9, 42), kind: 'reaction', body: _react('❤️'), target: 's5'),
    _row('r2', 'sunday', 10, f.dad.userId, t(9, 43), kind: 'reaction', body: _react('❤️'), target: 's5'),
    _row('s9', 'sunday', 11, f.mom.userId, t(9, 45), body: _text("Dinner at 6. I'll set a plate for Uncle Joe.")),
    _row('s10', 'sunday', 12, f.mom.userId, t(9, 45), body: _text('Can someone pick up bread on the way?')),
    _row('g1', 'gran', 1, f.mom.userId, y(20, 1), body: _text('Call you tomorrow?')),
    _row('g2', 'gran', 2, f.gran.userId, t(8, 15), body: _text('Yes dear, after my walk')),
    _row('g3', 'gran', 3, f.gran.userId, t(8, 16), body: _text('Bring the photo album!')),
    _row('k1', 'sam', 1, f.sam.userId, y(21, 30), body: _text('Train gets in at 4:40')),
    _row('k2', 'sam', 2, f.mom.userId, y(21, 31), body: _text("I'll pick you up")),
    _row('c4', 'cousins', 4, f.joe.userId, t(7, 50), body: _text('Fishing trip in May?')),
    _row('c5', 'cousins', 5, f.lily.userId, t(7, 58), kind: 'voice', body: jsonEncode(voice.toJson())),
    _row('d1', 'dad', 1, f.dad.userId, today.subtract(const Duration(days: 3)).add(const Duration(hours: 17)), body: _text('Car is fixed')),
  ];
  for (final r in rows) {
    await db.insertMessageIfAbsent(r);
  }
}

class _App extends ConsumerWidget {
  const _App({required this.dark});
  final bool dark;

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: _withEmoji(buildTheme(Brightness.light)),
        darkTheme: _withEmoji(buildTheme(Brightness.dark)),
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        routerConfig: ref.watch(routerProvider),
      );
}

Future<(ProviderContainer, ScriptedHubLink)> _pump(WidgetTester tester, _Family f, {required bool dark, bool signIn = true}) async {
  final hub = ScriptedHubLink();
  final photo = _sunset();
  await tester.runAsync(() async {
    await _seed(f);
    await Directory(f.mom.db, f.mom.api, f.mom.me).refresh();
  });
  final server = FakeServer();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      ...sessionOverrides(server, MemorySecureKv()),
      chatDbProvider.overrideWithValue(f.mom.db),
      chatApiProvider.overrideWithValue(f.mom.api),
      hubLinkProvider.overrideWithValue(hub),
      localIdentityProvider.overrideWith((ref) async => f.mom.me),
      mediaDbProvider.overrideWithValue(memoryMediaDb()),
      mediaApiProvider.overrideWithValue(f.mom.media),
      photoProcessorProvider.overrideWithValue(FakeProcessor()),
      mediaOffloadProvider.overrideWithValue(null),
      mediaBytesProvider.overrideWith((ref, _) async => photo),
      voiceRecorderFactoryProvider.overrideWithValue(FakeRecorders().call),
      voicePlayerFactoryProvider.overrideWithValue(() => FakeVoicePlayer()),
      voiceRecordingSupportedProvider.overrideWith((ref) async => true),
      developerToolsProvider.overrideWithValue(false),
    ],
    child: _App(dark: dark),
  ));
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(tester.element(find.byType(_App)));
  if (signIn) {
    await container.read(sessionProvider.notifier).join(token: server.addInvite(name: 'Mom', admin: true), deviceName: 'Kitchen iPad');
    await settle(tester);
    // The hub stays disconnected: connecting would resync with the fake server, which has no chats.
    hub.emit({'type': 'hello', 'online': [f.gran.userId, f.sam.userId]});
    await settle(tester);
  }
  return (container, hub);
}

/// Lets images decode (real async work), then settles.
Future<void> _images(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(_loadFonts);

  const phone = Size(400, 860), desktop = Size(1280, 800);

  void shot(
    String name,
    Size size,
    Future<void> Function(WidgetTester tester, bool dark) body, {
    List<bool> modes = const [false, true],
    TargetPlatform? platform,
  }) {
    for (final dark in modes) {
      final file = '$name-${dark ? 'dark' : 'light'}';
      testWidgets(file, (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        // The emoji picker's recently used list (this folder is a test, but outside test/).
        // ignore: invalid_use_of_visible_for_testing_member
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = size * 2;
        tester.view.devicePixelRatio = 2;
        tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
        await body(tester, dark);
        await _images(tester);
        await expectLater(find.byType(_App), matchesGoldenFile('../../docs/screenshots/$file.png'));
        await tester.pump(const Duration(seconds: 6)); // typing indicators expire
        await tester.pumpWidget(const SizedBox());
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }

  shot('phone-chats', phone, (tester, dark) async {
    final f = _Family();
    await f.create();
    await _pump(tester, f, dark: dark);
  });

  shot('phone-conversation', phone, (tester, dark) async {
    final f = _Family();
    await f.create();
    final (c, hub) = await _pump(tester, f, dark: dark);
    c.read(routerProvider).go('/chats/sunday');
    await settle(tester);
    hub.emit({'type': 'typing', 'chatId': 'sunday', 'userId': f.dad.userId});
    await settle(tester);
    await inApp(tester, () async {
      for (final u in [f.dad, f.gran, f.sam]) {
        await f.mom.db.setMemberRead('sunday', u.userId, 12);
      }
    });
    await settle(tester);
  });

  shot('desktop', desktop, (tester, dark) async {
    final f = _Family();
    await f.create();
    final (c, hub) = await _pump(tester, f, dark: dark);
    c.read(routerProvider).go('/chats/sunday');
    await settle(tester);
    hub.emit({'type': 'typing', 'chatId': 'sunday', 'userId': f.dad.userId});
    await settle(tester);
  });

  shot('phone-emoji', phone, (tester, dark) async {
    final f = _Family();
    await f.create();
    final (c, _) = await _pump(tester, f, dark: dark);
    c.read(routerProvider).go('/chats/sunday');
    await settle(tester);
    await tester.enterText(find.byKey(const Key('composer')), 'See you all Sunday ');
    await tester.tap(find.byTooltip('Emoji'));
    await settle(tester);
  });

  shot('desktop-emoji', desktop, (tester, dark) async {
    final f = _Family();
    await f.create();
    final (c, _) = await _pump(tester, f, dark: dark);
    c.read(routerProvider).go('/chats/sunday');
    await settle(tester);
    await tester.enterText(find.byKey(const Key('composer')), 'See you all Sunday ');
    await tester.tap(find.byTooltip('Emoji'));
    await settle(tester);
  }, platform: TargetPlatform.linux);

  shot('desktop-shortcodes', desktop, (tester, dark) async {
    final f = _Family();
    await f.create();
    final (c, _) = await _pump(tester, f, dark: dark);
    c.read(routerProvider).go('/chats/sunday');
    await settle(tester);
    await tester.enterText(find.byKey(const Key('composer')), 'Sounds great :ta');
    await settle(tester);
  }, platform: TargetPlatform.linux);

  shot('phone-join', phone, (tester, dark) async {
    final f = _Family();
    await f.create();
    await _pump(tester, f, dark: dark, signIn: false);
  });

  shot('desktop-join', desktop, (tester, dark) async {
    final f = _Family();
    await f.create();
    await _pump(tester, f, dark: dark, signIn: false);
  }, modes: const [false]);

  shot('phone-settings', phone, (tester, dark) async {
    final f = _Family();
    await f.create();
    final (c, _) = await _pump(tester, f, dark: dark);
    c.read(routerProvider).go('/settings');
    await settle(tester);
  });
}
