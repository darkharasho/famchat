// Files in a conversation: the bubble, opening and saving, sending from the + menu, and the
// one-line labels (chat list, notifications, replies, search).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:famchat/chat/chat_sync.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/files.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/chat/search.dart';
import 'package:famchat/chat/ulid.dart';
import 'package:famchat/crypto/media.dart';
import 'package:famchat/main.dart';
import 'package:famchat/media/file_actions.dart';
import 'package:famchat/media/media_service.dart' show maxFileBytes;
import 'package:famchat/push/preview.dart';
import 'package:famchat/router.dart';
import 'package:famchat/screens/chats/chat_list.dart' show preview;
import 'package:famchat/screens/chats/file_bubble.dart';
import 'package:famchat/share/share.dart';
import 'package:famchat/share/share_source.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';

final doc = Uint8List.fromList(List.generate(900, (i) => (i * 13) & 0xff));

MessageRow fileRow(String id, String from, FileBody body, {String chatId = 'c1', int seq = 1}) => MessageRow(
      id: id,
      chatId: chatId,
      seq: seq,
      senderUserId: from,
      senderDeviceId: 'x',
      kind: 'file',
      body: jsonEncode(body.toJson()),
      targetId: null,
      envelope: null,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      state: 'sent',
    );

FileBody someFile(String name, {int bytes = 900, String mime = 'application/pdf'}) => FileBody(
      mediaKey: newUlid(),
      key: Uint8List(32),
      sha256: Uint8List(32),
      name: name,
      bytes: bytes,
      mime: mime,
    );

void main() {
  group('labels', () {
    test('sizes', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(812), '812 B');
      expect(formatBytes(1024), '1 KB');
      expect(formatBytes(14 * 1024 + 300), '14 KB');
      expect(formatBytes((2.4 * 1024 * 1024).round()), '2.4 MB');
      expect(formatBytes((9.97 * 1024 * 1024).round()), '10 MB');
      expect(formatBytes(64 * 1024 * 1024), '64 MB');
      expect(formatBytes((1.1 * 1024 * 1024 * 1024).round()), '1.1 GB');
    });

    test('types and icons, by extension and else by MIME type', () {
      final cases = {
        ('Tax return.PDF', 'application/octet-stream'): (FileCategory.pdf, Icons.picture_as_pdf_outlined),
        ('letter.docx', ''): (FileCategory.document, Icons.description_outlined),
        ('budget.xlsx', ''): (FileCategory.spreadsheet, Icons.table_chart_outlined),
        ('talk.pptx', ''): (FileCategory.slides, Icons.slideshow_outlined),
        ('photos.zip', ''): (FileCategory.archive, Icons.folder_zip_outlined),
        ('song.mp3', ''): (FileCategory.audio, Icons.audio_file_outlined),
        ('main.dart', ''): (FileCategory.code, Icons.code_rounded),
        ('README', 'text/plain'): (FileCategory.code, Icons.code_rounded),
        ('scan', 'application/pdf'): (FileCategory.pdf, Icons.picture_as_pdf_outlined),
        ('blob', 'application/octet-stream'): (FileCategory.generic, Icons.insert_drive_file_outlined),
      };
      for (final MapEntry(key: (name, mime), value: (category, icon)) in cases.entries) {
        expect(fileCategoryOf(name, mime), category, reason: name);
        expect(fileIcon(category), icon, reason: name);
      }
      expect(fileTypeLabel('Tax return.PDF'), 'PDF');
      expect(fileTypeLabel('README'), 'File');
      expect(fileTypeLabel('.bashrc'), 'File');
      expect(mimeForName('notes.TXT'), 'text/plain');
      expect(mimeForName('thing.unknown'), isNull);
    });

    test('a tap opens only allowlisted types, judged by the name as written to disk', () {
      for (final n in ['a.pdf', 'b.JPG', 'c.mp3', 'd.mov', 'e.docx', 'f.xlsx', 'g.pptx', 'h.pages', 'i.txt', 'j.csv',
          'k.md', 'l.json', 'm.zip', 'n.7z', 'o.tar', 'p.gz', 'q.rar', 'setup.exe.pdf']) {
        expect(opensWithTap(diskFileName(n)), isTrue, reason: n);
      }
      for (final n in [
        'setup.exe', 'run.bat', 'x.ps1', 'x.py', 'x.pyw', 'x.msp', 'x.msc', 'x.scf', 'x.chm', 'x.application',
        'x.appref-ms', 'x.gadget', 'x.ws', 'x.wsc', 'x.sct', 'x.vb', 'x.settingcontent-ms', 'x.search-ms',
        'x.library-ms', 'x.diagcab', 'x.xll', 'x.xbap', 'x.jnlp', 'x.cab', 'x.iso', 'x.img', 'x.vhdx',
        'x.terminal', 'x.fileloc', 'x.scpt', 'x.dylib', 'x.command', 'x.app', 'x.html', 'x.svg', 'x.js', 'x.lnk',
        'macro.docm', 'macro.xlsm', 'macro.pptm', 'README', '.bashrc',
        // Windows drops trailing dots and spaces when writing: these land as programs.
        'evil.exe.', 'evil.bat..', 'evil.exe. .', 'evil.pdf.exe . ',
      ]) {
        expect(opensWithTap(diskFileName(n)), isFalse, reason: n);
      }
      // Names that went through the wire's cleaning too.
      expect(opensWithTap(diskFileName(cleanFileName('evil.exe.'))), isFalse);
    });

    test('names on disk: no characters Windows forbids, no device names, at most 255 bytes', () {
      expect(diskFileName('a<b>c:d"e|f?g*h.txt'), 'a_b_c_d_e_f_g_h.txt');
      expect(diskFileName('CON'), '_CON');
      expect(diskFileName('con.txt'), '_con.txt');
      expect(diskFileName('Lpt1.tar.gz'), '_Lpt1.tar.gz');
      expect(diskFileName('NUL .pdf'), '_NUL .pdf');
      expect(diskFileName('console.txt'), 'console.txt');
      expect(diskFileName('evil.exe. .'), 'evil.exe');
      expect(diskFileName('...'), 'file');
      expect(diskFileName('Résumé (final).docx'), 'Résumé (final).docx');
      final long = diskFileName('${'家' * 200}.pdf');
      expect(utf8.encode(long).length, lessThanOrEqualTo(255));
      expect(long, endsWith('.pdf'));
      expect(long, startsWith('家家'));
      expect(utf8.encode(diskFileName('${'😀' * 100}.txt')).length, lessThanOrEqualTo(255));
      expect(diskFileName('${'😀' * 100}.txt'), endsWith('😀.txt'), reason: 'no character split');
      expect(diskFileName('a' * 300), 'a' * 255);
    });

    test("shared paths in FamChat's own storage are refused, except straight in the cache", () {
      const private = ['/data/user/0/dev.famchat.app', '/data/data/dev.famchat.app'];
      const caches = ['/data/user/0/dev.famchat.app/cache', '/data/data/dev.famchat.app/cache'];
      bool ok(String p) => sharedPathAllowed(p, privateDirs: private, cacheDirs: caches);
      expect(ok('/data/user/0/dev.famchat.app/cache/plan.pdf'), isTrue, reason: 'the plugin copies streams here');
      expect(ok('/data/data/dev.famchat.app/cache/IMG_1.jpg'), isTrue);
      expect(ok('/storage/emulated/0/Download/plan.pdf'), isTrue);
      expect(ok('/data/user/0/dev.famchat.app.other/files/x'), isTrue, reason: 'another app');
      expect(ok('/data/user/0/dev.famchat.app/app_flutter/chat.sqlite'), isFalse);
      expect(ok('/data/data/dev.famchat.app/databases/x.db'), isFalse);
      expect(ok('/data/user/0/dev.famchat.app/files/key'), isFalse);
      expect(ok('/data/user/0/dev.famchat.app/cache/files/01J/Tax.pdf'), isFalse, reason: 'decrypted files');
      expect(ok('/data/user/0/dev.famchat.app/cache/video/play.mp4'), isFalse);
      expect(ok('/data/user/0/dev.famchat.app/cache/../files/key'), isFalse);
      expect(ok('/data/user/0/dev.famchat.app'), isFalse);
      expect(ok('/proc/self/environ'), isFalse, reason: "the process's own state");
      expect(ok('/proc/self/maps'), isFalse);
      expect(ok('/dev/zero'), isFalse);
      expect(ok('/sys/kernel/notes'), isFalse);
    });

    test('long names are cut in the middle, keeping the extension', () {
      expect(middleEllipsis('short.pdf'), 'short.pdf');
      final cut = middleEllipsis('Quarterly report for the family trust, second draft, final.pdf');
      expect(cut.length, 40);
      expect(cut, endsWith(' final.pdf'));
      expect(cut, startsWith('Quarterly report'));
      expect(cut, contains('…'));
    });

    test('chat list, notification and reply snippet show 📎 and the name', () async {
      final backend = FakeChatBackend();
      final alice = await backend.addUser('Alice');
      final m = fileRow('f1', 'bob', someFile('Tax return.pdf'));
      expect(preview(m, const {}, alice.userId), '📎 Tax return.pdf');
      expect(preview(fileRow('f2', alice.userId, someFile('a.zip')), const {}, alice.userId), 'You: 📎 a.zip');
      expect(await rowPreviewText(alice.db, m), '📎 Tax return.pdf');
      expect(fileLabel(someFile('two\nlines.txt')), '📎 two lines.txt');
    });

    test('search finds a file by its name', () async {
      final backend = FakeChatBackend();
      final alice = await backend.addUser('Alice');
      await alice.db.insertMessageIfAbsent(fileRow('f1', 'bob', someFile('Tax return 2026.pdf')));
      await alice.db.insertMessageIfAbsent(fileRow('f2', 'bob', someFile('recipes.txt'), seq: 2));
      final hits = await searchMessages(alice.db, 'tax');
      expect(hits.map((h) => (h.message.id, h.text)), [('f1', '📎 Tax return 2026.pdf')]);
    });

    test('shared files that are not photos or videos come in as files', () async {
      final dir = await Directory.systemTemp.createTemp('share');
      addTearDown(() => dir.delete(recursive: true));
      final pdf = File('${dir.path}/plan.pdf')..writeAsBytesSync(doc);
      final txt = File('${dir.path}/list.txt')..writeAsBytesSync(utf8.encode('eggs'));
      final s = await sharedToIncoming(allow: (_) => true, [
        SharedMediaFile(path: pdf.path, type: SharedMediaType.file, mimeType: 'application/pdf'),
        // Android calls a shared text file "text", with its path.
        SharedMediaFile(path: txt.path, type: SharedMediaType.text, mimeType: 'text/plain'),
        SharedMediaFile(path: 'see you /soon', type: SharedMediaType.text, mimeType: 'text/plain'),
      ]);
      expect(s.files.map((f) => f.name), ['plan.pdf', 'list.txt']);
      expect(s.media, isEmpty);
      expect(s.text, 'see you /soon');
      expect(shareSummary(s), '2 files and a message');

      // What the filter refuses is dropped, photos and text files included.
      final refused = await sharedToIncoming(allow: (p) => p != txt.path, [
        SharedMediaFile(path: txt.path, type: SharedMediaType.text, mimeType: 'text/plain'),
        SharedMediaFile(path: pdf.path, type: SharedMediaType.image, mimeType: 'image/png'),
        SharedMediaFile(path: txt.path, type: SharedMediaType.file),
      ]);
      expect(refused.files, isEmpty);
      expect(refused.text, isNull);
      expect(refused.media, hasLength(1));
    });
  });

  group('in a chat', () {
    late FakeChatBackend backend;
    late TestDevice alice, bob;
    late FakeFileActions actions;
    late List<OutgoingFile> toPick;

    /// Each file's encrypted blob, by media key.
    final blobs = <String, Uint8List>{};

    setUp(() async {
      backend = FakeChatBackend();
      alice = await backend.addUser('Alice');
      bob = await backend.addUser('Bob');
      actions = FakeFileActions();
      toPick = [];
    });

    Future<String> open(WidgetTester tester) async {
      setWindow(tester, const Size(400, 800));
      await pumpChatApp(tester, alice, fileActions: actions, filePicker: () async => toPick);
      final chatId = await inApp(tester, () => ChatSync(db: alice.db, api: alice.api, hub: alice.hub, me: alice.me).openDirect(bob.userId));
      ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider).go('/chats/$chatId');
      await settle(tester);
      return chatId;
    }

    /// Bob's file: the blob on the server (unless [upload] is false), the message in Alice's database.
    Future<(FileBody, String)> bobsFile(WidgetTester tester, String chatId, String name, {bool upload = true}) =>
        inApp(tester, () async {
          final key = newMediaKey();
          final blob = await encryptMedia(key: key, plaintext: doc, purpose: MediaPurpose.file);
          final body = FileBody(
            mediaKey: newUlid(),
            key: key,
            sha256: await sha256Of(blob),
            name: name,
            bytes: doc.length,
            mime: 'application/pdf',
          );
          blobs[body.mediaKey] = blob;
          if (upload) await bob.media.upload(key: body.mediaKey, chatId: chatId, kind: 'file', bytes: blob);
          final id = newUlid();
          await alice.db.insertMessageIfAbsent(fileRow(id, bob.userId, body, chatId: chatId));
          return (body, id);
        });

    Future<List<MessageRow>> outbox(WidgetTester tester) => inApp(tester, () => alice.db.pendingOutbox(alice.deviceId));

    chatTestWidgets('the bubble shows the icon, name, size and type; a tap opens the decrypted file', (tester) async {
      final chatId = await open(tester);
      final (_, id) = await bobsFile(tester, chatId, 'Tax return.pdf');
      await settle(tester);
      expect(find.byType(FileBubble), findsOneWidget);
      expect(find.text('Tax return.pdf'), findsOneWidget);
      expect(find.text('900 B · PDF'), findsOneWidget);
      expect(find.byKey(const Key('file-icon-pdf')), findsOneWidget);

      await tester.tap(find.byKey(Key('file-$id')));
      await settle(tester);
      expect(actions.opened, hasLength(1));
      expect(actions.opened.single.id, id);
      expect(actions.opened.single.name, 'Tax return.pdf');
      expect(actions.opened.single.mime, 'application/pdf');
      expect(actions.opened.single.bytes, doc);
    });

    chatTestWidgets('a download that fails shows retry, and retrying opens it', (tester) async {
      final chatId = await open(tester);
      final (body, id) = await bobsFile(tester, chatId, 'plan.pdf', upload: false);
      await settle(tester);
      await tester.tap(find.byKey(Key('file-$id')));
      await settle(tester);
      expect(find.byKey(const Key('file-retry')), findsOneWidget);
      expect(find.text("Couldn't download. Tap to retry"), findsOneWidget);
      expect(actions.opened, isEmpty);

      await inApp(tester, () => bob.media.upload(key: body.mediaKey, chatId: chatId, kind: 'file', bytes: blobs[body.mediaKey]!));
      await tester.tap(find.byKey(Key('file-$id')));
      await settle(tester);
      expect(find.byKey(const Key('file-retry')), findsNothing);
      expect(actions.opened.single.bytes, doc);
    });

    chatTestWidgets('nothing to open it with says so', (tester) async {
      final chatId = await open(tester);
      final (_, id) = await bobsFile(tester, chatId, 'plan.pages');
      await settle(tester);
      actions.outcome = OpenOutcome.noApp;
      await tester.tap(find.byKey(Key('file-$id')));
      await settle(tester);
      expect(find.text('Nothing here can open "plan.pages". Save it instead.'), findsOneWidget);
    });

    chatTestWidgets("programs aren't opened, only saved", (tester) async {
      final chatId = await open(tester);
      final (_, id) = await bobsFile(tester, chatId, 'setup.exe');
      await settle(tester);
      await tester.tap(find.byKey(Key('file-$id')));
      await settle(tester);
      expect(actions.opened, isEmpty);
      expect(find.textContaining('FamChat only opens documents'), findsOneWidget);
      await tester.tap(find.widgetWithText(SnackBarAction, 'Save'));
      await settle(tester);
      expect(actions.saved.single.name, 'setup.exe');
      expect(actions.saved.single.bytes, doc);
    });

    chatTestWidgets('Save from the actions saves a copy', (tester) async {
      final chatId = await open(tester);
      await bobsFile(tester, chatId, 'Tax return.pdf');
      await settle(tester);
      await tester.longPress(find.text('Tax return.pdf'));
      await settle(tester);
      expect(find.text('Forward'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await settle(tester);
      expect(actions.saved.single.name, 'Tax return.pdf');
      expect(actions.saved.single.mime, 'application/pdf');
      expect(find.text('Saved'), findsOneWidget);
    });

    chatTestWidgets('File in the + menu sends each file picked; the first replies', (tester) async {
      final chatId = await open(tester);
      await bobsFile(tester, chatId, 'plan.pdf');
      await settle(tester);
      await tester.longPress(find.text('plan.pdf'));
      await settle(tester);
      await tester.tap(find.text('Reply'));
      await settle(tester);
      expect(find.text('📎 plan.pdf'), findsOneWidget, reason: 'the reply banner');

      toPick = [
        OutgoingFile.bytes('notes.txt', Uint8List.fromList(utf8.encode('milk, eggs'))),
        OutgoingFile.bytes('scan', doc, mime: 'application/pdf'),
      ];
      await tester.tap(find.byTooltip('Attach'));
      await settle(tester);
      await tester.tap(find.text('File'));
      await settle(tester);

      final sent = [for (final r in await outbox(tester)) Plaintext.decode(utf8.encode(r.body!)) as FileBody];
      expect(sent.map((f) => (f.name, f.mime, f.bytes)), [('notes.txt', 'text/plain', 10), ('scan', 'application/pdf', doc.length)]);
      expect(sent.first.replyTo, isNotNull);
      expect(sent.last.replyTo, isNull);
      expect(find.textContaining('Replying to'), findsNothing, reason: 'the reply is done');
      expect(find.text('notes.txt'), findsOneWidget);
    });

    chatTestWidgets('a file over 64 MB is refused before it is read, by name', (tester) async {
      await open(tester);
      var read = false;
      toPick = [
        OutgoingFile(
          name: 'holiday.iso',
          length: () async => maxFileBytes + 1,
          read: () async {
            read = true;
            return Uint8List(0);
          },
        ),
      ];
      await tester.tap(find.byTooltip('Attach'));
      await settle(tester);
      await tester.tap(find.text('File'));
      await settle(tester);
      expect(find.text('"holiday.iso" is too large to send (64 MB max).'), findsOneWidget);
      expect(read, isFalse);
      expect(await outbox(tester), isEmpty);
    });

    chatTestWidgets('a file of unknown size is read only up to the limit', (tester) async {
      await open(tester);
      var chunks = 0;
      Stream<List<int>> endless() async* {
        while (true) {
          chunks++;
          yield Uint8List(4 * 1024 * 1024);
        }
      }

      toPick = [
        OutgoingFile(name: 'stream.bin', length: () async => null, read: () => throw StateError('read whole'), openRead: endless),
        OutgoingFile(
          name: 'small.txt',
          length: () async => null,
          read: () => throw StateError('read whole'),
          openRead: () => Stream.value(utf8.encode('hello')),
        ),
      ];
      await tester.tap(find.byTooltip('Attach'));
      await settle(tester);
      await tester.tap(find.text('File'));
      await settle(tester);
      expect(find.text('"stream.bin" is too large to send (64 MB max).'), findsOneWidget);
      expect(chunks, lessThanOrEqualTo(maxFileBytes ~/ (4 * 1024 * 1024) + 2));
      final sent = [for (final r in await outbox(tester)) Plaintext.decode(utf8.encode(r.body!)) as FileBody];
      expect(sent.map((f) => (f.name, f.bytes)), [('small.txt', 5)]);
    });

    chatTestWidgets('the chat list shows 📎 and the name', (tester) async {
      final chatId = await open(tester);
      await bobsFile(tester, chatId, 'Tax return.pdf');
      ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider).go('/');
      await settle(tester);
      expect(find.text('📎 Tax return.pdf'), findsOneWidget);
    });
  });
}
