import 'package:famchat/update/build_info.dart';
import 'package:famchat/update/update_banner.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('versionLine', () {
    test('a store build shows its version and build number', () {
      expect(versionLine(const BuildInfo(version: '1.0.10', build: '29915682', web: false)), 'FamChat 1.0.10 (build 29915682)');
    });

    test('a release without a build number shows just the version', () {
      expect(versionLine(const BuildInfo(version: '1.0.10', web: false)), 'FamChat 1.0.10');
    });

    test('the web app shows when it was deployed and from which commit', () {
      expect(
        versionLine(const BuildInfo(commit: 'dcff4ff', built: '2026-11-17', web: true)),
        'FamChat web · deployed Nov 17, 2026 · dcff4ff',
      );
    });

    test('the web app without a deploy date still shows its commit', () {
      expect(versionLine(const BuildInfo(commit: 'dcff4ff', web: true)), 'FamChat web · dcff4ff');
    });

    test('a local build says so', () {
      expect(versionLine(const BuildInfo(web: false)), 'FamChat (local build)');
      expect(versionLine(const BuildInfo(web: true)), 'FamChat web (local build)');
    });
  });

  testWidgets('phones show their version in settings', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [buildInfoProvider.overrideWithValue(const BuildInfo(version: '1.0.10', build: '42', web: false))],
      child: const MaterialApp(home: Scaffold(body: Column(children: [AppVersionGroup()]))),
    ));
    expect(find.text('FamChat 1.0.10 (build 42)'), findsOneWidget);
    expect(find.text('Get the apps'), findsNothing);
  });

  testWidgets('the web app shows its deploy next to the download link', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        buildInfoProvider.overrideWithValue(const BuildInfo(commit: 'abc1234', built: '2026-01-05', web: true)),
        appDownloadsProvider.overrideWithValue((_) async => true),
      ],
      child: const MaterialApp(home: Scaffold(body: Column(children: [AppVersionGroup()]))),
    ));
    expect(find.text('FamChat web · deployed Jan 5, 2026 · abc1234'), findsOneWidget);
    expect(find.text('Reload the page to get the newest version.'), findsOneWidget);
    expect(find.text('Get the apps'), findsOneWidget);
  });
}
