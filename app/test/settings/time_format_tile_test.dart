import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:famchat/settings/time_format.dart';
import 'package:famchat/settings/time_format_tile.dart';

class FakeTimeFormat extends TimeFormatNotifier {
  FakeTimeFormat(this.initial, {this.fail = false});
  final TimeFormat initial;
  final bool fail;
  final sets = <TimeFormat>[];
  @override
  Future<TimeFormat> build() async {
    if (fail) throw StateError('unreadable');
    return initial;
  }

  @override
  Future<void> set(TimeFormat f) async {
    sets.add(f);
    state = AsyncData(f);
  }
}

Future<bool> readDevice24(WidgetTester t, FakeTimeFormat fake, {required bool device}) async {
  late bool seen;
  await t.pumpWidget(ProviderScope(
    overrides: [timeFormatProvider.overrideWith(() => fake)],
    child: MediaQuery(
      data: MediaQueryData(alwaysUse24HourFormat: device),
      child: TimeFormatScope(
        child: Builder(builder: (context) {
          seen = MediaQuery.alwaysUse24HourFormatOf(context);
          return const SizedBox.shrink();
        }),
      ),
    ),
  ));
  await t.pumpAndSettle();
  return seen;
}

void main() {
  testWidgets('TimeFormatScope: 12-hour overrides a 24-hour device', (t) async {
    expect(await readDevice24(t, FakeTimeFormat(TimeFormat.h12), device: true), isFalse);
  });

  testWidgets('TimeFormatScope: Automatic follows the device', (t) async {
    expect(await readDevice24(t, FakeTimeFormat(TimeFormat.automatic), device: true), isTrue);
  });

  testWidgets('TimeFormatScope: unreadable setting falls back to the device', (t) async {
    expect(await readDevice24(t, FakeTimeFormat(TimeFormat.h12, fail: true), device: true), isTrue);
    expect(t.takeException(), isNull);
  });

  testWidgets('Display group: shows the current choice and changes it', (t) async {
    final fake = FakeTimeFormat(TimeFormat.automatic);
    await t.pumpWidget(ProviderScope(
      overrides: [timeFormatProvider.overrideWith(() => fake)],
      child: const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: DisplaySettingsGroup()))),
    ));
    await t.pumpAndSettle();
    expect(find.text('Time format'), findsOneWidget);
    expect(find.text('Automatic'), findsOneWidget);

    await t.tap(find.byKey(const Key('settings-time-format')));
    await t.pumpAndSettle();
    expect(find.text('Automatic'), findsNWidgets(2));
    expect(find.text('12-hour'), findsOneWidget);
    expect(find.text('24-hour'), findsOneWidget);

    await t.tap(find.text('12-hour'));
    await t.pumpAndSettle();
    expect(fake.sets, [TimeFormat.h12]);
    expect(find.text('12-hour'), findsOneWidget);
    expect(find.text('Automatic'), findsNothing);
  });

  Future<FakeTimeFormat> pumpGroup(WidgetTester t, TimeFormat initial) async {
    final fake = FakeTimeFormat(initial);
    await t.pumpWidget(ProviderScope(
      overrides: [timeFormatProvider.overrideWith(() => fake)],
      child: const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: DisplaySettingsGroup()))),
    ));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('settings-time-format')));
    await t.pumpAndSettle();
    return fake;
  }

  testWidgets('Display group: choosing 24-hour', (t) async {
    final fake = await pumpGroup(t, TimeFormat.automatic);
    await t.tap(find.text('24-hour'));
    await t.pumpAndSettle();
    expect(fake.sets, [TimeFormat.h24]);
    expect(find.text('24-hour'), findsOneWidget);
  });

  testWidgets('Display group: tapping the current choice closes the dialog without a change', (t) async {
    final fake = await pumpGroup(t, TimeFormat.automatic);
    expect(find.byType(SimpleDialog), findsOneWidget);
    await t.tap(find.descendant(of: find.byType(SimpleDialog), matching: find.text('Automatic')));
    await t.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsNothing);
    expect(fake.sets, isEmpty);
  });
}
