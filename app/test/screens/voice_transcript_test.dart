import 'dart:typed_data';

import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/media/providers.dart';
import 'package:famchat/screens/chats/voice_bubble.dart';
import 'package:famchat/theme/app_theme.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final clip = VoiceBody(
  mediaKey: '01JC0000000000000000000000',
  key: Uint8List(32),
  sha256: Uint8List(32),
  durationMs: 4200,
  waveform: const [10, 200, 90],
  bytes: 100,
);

Future<void> pump(WidgetTester tester, {String? transcript}) => tester.pumpWidget(ProviderScope(
      overrides: [mediaServiceProvider.overrideWithValue(null)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: SingleChildScrollView(child: VoiceBubble(body: clip, messageId: 'v', transcript: transcript))),
      ),
    ));

Text transcriptText(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('voice-transcript')));

void main() {
  testWidgets('shows the transcript under the waveform, three lines collapsed', (tester) async {
    await pump(tester, transcript: 'x' * 20000);
    final t = transcriptText(tester);
    expect(t.maxLines, 3);
    expect(t.overflow, TextOverflow.ellipsis);
    expect(tester.getTopLeft(find.byKey(const Key('voice-transcript'))).dy,
        greaterThan(tester.getBottomLeft(find.byKey(const Key('voice-waveform'))).dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping the transcript expands it', (tester) async {
    await pump(tester, transcript: 'pick up milk ' * 40);
    await tester.tap(find.byKey(const Key('voice-transcript')));
    await tester.pump();
    expect(transcriptText(tester).maxLines, isNull);
  });

  testWidgets('no transcript, no text', (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('voice-transcript')), findsNothing);
  });
}
