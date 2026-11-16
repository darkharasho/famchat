import 'package:famchat/theme/contrast.dart';
import 'package:famchat/theme/person_colors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the same id always gets the same color', () {
    expect(personColor('01JC00000000000000000000AB'), personColor('01JC00000000000000000000AB'));
    expect(personHueIndex('alice'), personHueIndex('alice'));
  });

  test('hues match FNV-1a over UTF-16 units (pinned, so native and web agree)', () {
    // Expected values computed independently (Python, 32-bit FNV-1a over UTF-16LE units).
    expect(personHueIndex('alice'), 7);
    expect(personHueIndex('01JC00000000000000000000AB'), 6);
    expect(personHueIndex('Grandma Rose'), 2);
    expect(personHueIndex('ü€😀'), 0);
  });

  test('ids spread over every hue', () {
    final used = {for (var i = 0; i < 200; i++) personHueIndex('01JC0000000000000000000${i.toString().padLeft(3, '0')}')};
    expect(used, hasLength(personHues.length));
  });

  test('initials read on every hue', () {
    for (final bg in personHues) {
      expect(contrastRatio(onColorFor(bg), bg), greaterThanOrEqualTo(4.5), reason: bg.toString());
    }
  });
}
