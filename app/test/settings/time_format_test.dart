import 'package:famchat/settings/time_format.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(
    () => SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty(),
  );

  test('24-hour', () {
    expect(clockTime(DateTime(2026, 1, 1, 14, 5), h24: true), '14:05');
    expect(clockTime(DateTime(2026, 1, 1, 8, 5), h24: true), '08:05');
  });

  test('12-hour: no leading zero, AM/PM, midnight and noon are 12', () {
    expect(clockTime(DateTime(2026, 1, 1, 14, 5), h24: false), '2:05 PM');
    expect(clockTime(DateTime(2026, 1, 1, 0, 0), h24: false), '12:00 AM');
    expect(clockTime(DateTime(2026, 1, 1, 12, 30), h24: false), '12:30 PM');
    expect(clockTime(DateTime(2026, 1, 1, 9, 7), h24: false), '9:07 AM');
  });

  test('use24Hour', () {
    expect(use24Hour(TimeFormat.automatic, device: true), isTrue);
    expect(use24Hour(TimeFormat.automatic, device: false), isFalse);
    expect(use24Hour(TimeFormat.h12, device: true), isFalse);
    expect(use24Hour(TimeFormat.h24, device: false), isTrue);
  });

  test('Automatic by default; a written value is read back; junk reads as Automatic', () async {
    expect(await readTimeFormat(), TimeFormat.automatic);
    await writeTimeFormat(TimeFormat.h12);
    expect(await readTimeFormat(), TimeFormat.h12);
    await SharedPreferencesAsync().setString(timeFormatPrefKey, 'nonsense');
    expect(await readTimeFormat(), TimeFormat.automatic);
  });
}
