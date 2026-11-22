import 'package:cross_file/cross_file.dart';
import 'package:famchat/media/photo_picker.dart';
import 'package:famchat/media/staged_media.dart';
import 'package:famchat/screens/chats/staged_tray.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fake_media.dart';

void main() {
  testWidgets('shows each staged item with ✕, and + to add more', (tester) async {
    final removed = <int>[];
    var added = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StagedTray(
          items: [
            PickedPhoto(photoBytes(10)),
            PickedVideo(XFile.fromData(photoBytes(10), path: '/v/a.mp4')),
            PickedPhoto(photoBytes(10)),
          ],
          onRemove: removed.add,
          onAdd: () => added++,
        ),
      ),
    ));
    expect(find.text('3 items · your message goes with them'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    await tester.tap(find.byKey(const Key('staged-remove-1')));
    await tester.tap(find.byKey(const Key('staged-add')));
    expect(removed, [1]);
    expect(added, 1);
  });

  test('staged media is kept per chat, in order, up to the limit', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final a = c.read(stagedMediaProvider('a').notifier);
    final p1 = PickedPhoto(photoBytes(1)), p2 = PickedPhoto(photoBytes(2));
    expect(a.add([p1, p2]), 0);
    expect(c.read(stagedMediaProvider('a')), [p1, p2]);
    expect(c.read(stagedMediaProvider('b')), isEmpty);
    a.removeAt(0);
    expect(c.read(stagedMediaProvider('a')), [p2]);
    expect(a.add(List.filled(maxStagedMedia, p1)), 1);
    expect(c.read(stagedMediaProvider('a')).length, maxStagedMedia);
    a.clear();
    expect(c.read(stagedMediaProvider('a')), isEmpty);
  });
}
