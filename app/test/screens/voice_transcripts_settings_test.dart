import 'package:famchat/settings/voice_transcripts.dart';
import 'package:famchat/settings/voice_transcripts_group.dart';
import 'package:famchat/theme/app_theme.dart';
import 'package:famchat/transcripts/model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _paths = ModelPaths(encoder: 'e', decoder: 'd', tokens: 't', vad: 'v');

class _FakeModel extends TranscriptModel {
  _FakeModel(this.initial);
  final ModelState initial;
  int downloads = 0, cancels = 0, removes = 0;
  @override
  ModelState build() => initial;
  @override
  Future<void> download() async {
    downloads++;
    state = const ModelDownloading(40000000, 160609290);
  }

  @override
  void cancel() {
    cancels++;
    state = const ModelAbsent();
  }

  @override
  Future<void> remove() async {
    removes++;
    state = const ModelAbsent();
  }
}

void main() {
  setUp(() => SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty());

  Future<_FakeModel> pump(WidgetTester tester, ModelState initial) async {
    final fake = _FakeModel(initial);
    await tester.pumpWidget(ProviderScope(
      overrides: [transcriptModelProvider.overrideWith(() => fake)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const Scaffold(body: SingleChildScrollView(child: VoiceTranscriptsGroup(onWeb: false))),
      ),
    ));
    await tester.pumpAndSettle();
    return fake;
  }

  testWidgets('toggling on with no model starts the download', (tester) async {
    final fake = await pump(tester, const ModelAbsent());
    expect(find.textContaining('Downloads a 161 MB speech model'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-voice-transcripts')));
    await tester.pumpAndSettle();
    expect(fake.downloads, 1);
    expect(await SharedPreferencesAsync().getBool(voiceTranscriptsPrefKey), isTrue);
  });

  testWidgets('shows progress and cancel while downloading', (tester) async {
    final fake = await pump(tester, const ModelDownloading(40000000, 160609290));
    expect(find.byKey(const Key('transcripts-progress')), findsOneWidget);
    expect(find.text('Downloading… 40 MB of 161 MB'), findsOneWidget);
    await tester.tap(find.byKey(const Key('transcripts-cancel')));
    await tester.pumpAndSettle();
    expect(fake.cancels, 1);
    expect(find.byKey(const Key('transcripts-progress')), findsNothing);
  });

  testWidgets('remove model only when ready, and asks first', (tester) async {
    await pump(tester, const ModelAbsent());
    expect(find.byKey(const Key('transcripts-remove')), findsNothing);
  });

  testWidgets('remove model asks, then removes', (tester) async {
    final fake = await pump(tester, const ModelReady(_paths));
    await tester.tap(find.byKey(const Key('transcripts-remove')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(fake.removes, 0);
    await tester.tap(find.byKey(const Key('transcripts-remove')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(fake.removes, 1);
    expect(find.byKey(const Key('transcripts-remove')), findsNothing);
  });

  testWidgets('nothing on the web', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: VoiceTranscriptsGroup(onWeb: true))));
    expect(find.text('Voice transcripts'), findsNothing);
  });
}
