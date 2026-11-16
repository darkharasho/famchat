import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:famchat/update/release_feed.dart';
import 'package:famchat/update/update_banner.dart';
import 'package:famchat/update/update_controller.dart';
import 'package:famchat/update/update_platform.dart';
import 'package:famchat/update/update_platform_io.dart' show downloadVerified;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String releaseJson({
  String tag = 'v1.2.0',
  bool prerelease = false,
  bool draft = false,
  String? digest = 'sha256:ABCDEF',
  List<String> names = const [
    'FamChat-1.2.0-linux-x86_64.AppImage',
    'FamChat-1.2.0-macos.dmg',
    'FamChat-1.2.0-windows-x64-setup.exe',
  ],
}) =>
    jsonEncode({
      'tag_name': tag,
      'draft': draft,
      'prerelease': prerelease,
      'html_url': 'https://github.com/darkharasho/famchat/releases/tag/$tag',
      'assets': [
        for (final n in names)
          {
            'name': n,
            'browser_download_url': 'https://github.com/darkharasho/famchat/releases/download/$tag/$n',
            'size': 10,
            'digest': ?digest,
          },
      ],
    });

class FakePlatform implements UpdatePlatform {
  FakePlatform({this.platform = 'linux', this.canSelfInstall = true, this.failDownload = false});

  @override
  final String platform;
  @override
  final bool canSelfInstall;
  final bool failDownload;
  final downloaded = <String>[];
  final installed = <String>[];

  @override
  Future<String> download(ReleaseAsset asset, http.Client client, void Function(double) onProgress) async {
    onProgress(0.5);
    if (failDownload) throw const UpdateException("The download didn't match its checksum.");
    downloaded.add(asset.name);
    return '/tmp/${asset.name}';
  }

  @override
  Future<void> installAndRestart(String downloaded) async => installed.add(downloaded);
}

void main() {
  group('release feed', () {
    test('picks the asset for each platform, with its digest', () {
      for (final (platform, suffix) in [
        ('linux', '.AppImage'),
        ('windows', '-setup.exe'),
        ('macos', '.dmg'),
      ]) {
        final r = parseRelease(releaseJson(), platform: platform)!;
        expect(r.version, '1.2.0');
        expect(r.asset!.name, endsWith(suffix));
        expect(r.asset!.sha256, 'abcdef');
        expect(r.asset!.url.scheme, 'https');
      }
    });

    test('rejects drafts, prereleases, odd tags and junk', () {
      expect(parseRelease(releaseJson(prerelease: true), platform: 'linux'), isNull);
      expect(parseRelease(releaseJson(draft: true), platform: 'linux'), isNull);
      expect(parseRelease(releaseJson(tag: 'v1.2.0-beta.1'), platform: 'linux'), isNull);
      expect(parseRelease(releaseJson(tag: 'nightly'), platform: 'linux'), isNull);
      expect(parseRelease('not json', platform: 'linux'), isNull);
      expect(parseRelease('[]', platform: 'linux'), isNull);
    });

    test('a release without this platform has no asset; a missing digest is null', () {
      expect(parseRelease(releaseJson(names: ['FamChat-1.2.0-macos.dmg']), platform: 'linux')!.asset, isNull);
      expect(parseRelease(releaseJson(digest: null), platform: 'linux')!.asset!.sha256, isNull);
    });

    test('compares versions numerically', () {
      expect(isNewerVersion('1.0.10', '1.0.9'), isTrue);
      expect(isNewerVersion('2.0.0', '1.9.9'), isTrue);
      expect(isNewerVersion('1.0.1', '1.0.1'), isFalse);
      expect(isNewerVersion('1.0.0', '1.0.1'), isFalse);
      expect(isNewerVersion('1.0', '0.9.0'), isFalse);
      expect(isNewerVersion('1.0.1', ''), isFalse);
    });
  });

  group('downloadVerified', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('famchat_update_test'));
    tearDown(() async => dir.delete(recursive: true));

    Future<String> sha(List<int> bytes) async =>
        (await Sha256().hash(bytes)).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    ReleaseAsset asset(String? digest) => ReleaseAsset(
        name: 'FamChat-1.2.0-linux-x86_64.AppImage', url: Uri.parse('https://example.test/a'), sha256: digest, size: 5);

    test('keeps a file whose checksum matches and reports progress', () async {
      final body = utf8.encode('hello');
      final client = MockClient((_) async => http.Response.bytes(body, 200));
      final target = File('${dir.path}/a');
      final progress = <double>[];
      await downloadVerified(asset(await sha(body)), client, target, progress.add);
      expect(await target.readAsBytes(), body);
      expect(progress.last, 1.0);
    });

    test('deletes a file whose checksum is wrong', () async {
      final client = MockClient((_) async => http.Response('hello', 200));
      final target = File('${dir.path}/a');
      await expectLater(downloadVerified(asset('00' * 32), client, target, (_) {}), throwsA(isA<UpdateException>()));
      expect(await target.exists(), isFalse);
    });

    test('refuses a download without a checksum, and an HTTP error', () async {
      final ok = MockClient((_) async => http.Response('hello', 200));
      await expectLater(downloadVerified(asset(null), ok, File('${dir.path}/a'), (_) {}), throwsA(isA<UpdateException>()));
      final missing = MockClient((_) async => http.Response('nope', 404));
      final target = File('${dir.path}/b');
      await expectLater(
          downloadVerified(asset(await sha(utf8.encode('nope'))), missing, target, (_) {}), throwsA(isA<UpdateException>()));
      expect(await target.exists(), isFalse);
    });
  });

  group('UpdateController', () {
    ProviderContainer container(UpdatePlatform platform, {String body = '', int status = 200, List<Uri>? opened}) {
      final c = ProviderContainer(overrides: [
        updateConfigProvider.overrideWithValue(UpdateConfig(
          currentVersion: '1.0.1',
          platform: platform,
          newClient: () => MockClient((req) async {
            expect(req.url, latestReleaseUrl);
            return http.Response(body, status);
          }),
          openUrl: (u) async {
            opened?.add(u);
            return true;
          },
          firstCheckDelay: const Duration(days: 1),
        )),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test('downloads a newer release and installs it on restart', () async {
      final platform = FakePlatform();
      final c = container(platform, body: releaseJson());
      await c.read(updateProvider.notifier).check();
      final s = c.read(updateProvider);
      expect(s, isA<UpdateReady>());
      expect((s as UpdateReady).release.version, '1.2.0');
      expect(c.read(updateProvider.notifier).showBanner, isTrue);
      await c.read(updateProvider.notifier).restart();
      expect(platform.installed, ['/tmp/FamChat-1.2.0-linux-x86_64.AppImage']);
    });

    test('is up to date when the latest release is this version or older', () async {
      final c = container(FakePlatform(), body: releaseJson(tag: 'v1.0.1'));
      await c.read(updateProvider.notifier).check();
      expect(c.read(updateProvider), isA<UpdateIdle>().having((s) => s.checked, 'checked', isTrue));
      expect(c.read(updateProvider.notifier).showBanner, isFalse);
    });

    test('offers the download where the app cannot install itself', () async {
      final opened = <Uri>[];
      final platform = FakePlatform(platform: 'macos', canSelfInstall: false);
      final c = container(platform, body: releaseJson(), opened: opened);
      await c.read(updateProvider.notifier).check();
      expect(c.read(updateProvider), isA<UpdateAvailable>());
      expect(platform.downloaded, isEmpty);
      await c.read(updateProvider.notifier).openDownload();
      expect(opened.single.path, endsWith('FamChat-1.2.0-macos.dmg'));
    });

    test('falls back to the download link when the download fails or has no checksum', () async {
      final failing = container(FakePlatform(failDownload: true), body: releaseJson());
      await failing.read(updateProvider.notifier).check();
      expect(failing.read(updateProvider), isA<UpdateAvailable>().having((s) => s.error, 'error', isNotNull));

      final platform = FakePlatform();
      final unsigned = container(platform, body: releaseJson(digest: null));
      await unsigned.read(updateProvider.notifier).check();
      expect(unsigned.read(updateProvider), isA<UpdateAvailable>());
      expect(platform.downloaded, isEmpty);
    });

    test('reports a failed check without offering anything', () async {
      final c = container(FakePlatform(), status: 403);
      await c.read(updateProvider.notifier).check();
      expect(c.read(updateProvider), isA<UpdateIdle>().having((s) => s.error, 'error', isNotNull));
    });

    test('Not now hides the banner until a later version', () async {
      final c = container(FakePlatform(), body: releaseJson());
      final updates = c.read(updateProvider.notifier);
      await updates.check();
      updates.dismiss();
      expect(updates.showBanner, isFalse);
    });

    test('is off without a release version', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(updateConfigProvider), isNull); // tests build without FAMCHAT_VERSION
      expect(c.read(updateProvider), isA<UpdateIdle>());
    });
  });

  testWidgets('the banner restarts into a downloaded update', (tester) async {
    final platform = FakePlatform();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        updateConfigProvider.overrideWithValue(UpdateConfig(
          currentVersion: '1.0.1',
          platform: platform,
          newClient: () => MockClient((_) async => http.Response(releaseJson(), 200)),
          openUrl: (_) async => true,
          firstCheckDelay: const Duration(milliseconds: 1),
        )),
      ],
      child: const MaterialApp(home: Scaffold(body: Column(children: [UpdateBanner()]))),
    ));
    expect(find.byKey(const Key('update-ready')), findsNothing);
    await tester.pump(const Duration(milliseconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('FamChat 1.2.0 is ready. Restart to update.'), findsOneWidget);
    await tester.tap(find.text('Restart'));
    await tester.pump();
    expect(platform.installed, hasLength(1));
  });

  testWidgets('the web app links to the desktop and phone apps', (tester) async {
    Uri? opened;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appDownloadsProvider.overrideWithValue((u) async {
          opened = u;
          return true;
        }),
      ],
      child: const MaterialApp(home: Scaffold(body: Column(children: [AppVersionGroup()]))),
    ));
    expect(find.text('Get the apps'), findsOneWidget);
    await tester.tap(find.text('Get the apps'));
    await tester.pump();
    expect(opened?.path, '/download.html');
  });

  testWidgets('installed apps show no download link', (tester) async {
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: Scaffold(body: Column(children: [AppVersionGroup()]))),
    ));
    expect(find.text('Get the apps'), findsNothing);
  });
}
