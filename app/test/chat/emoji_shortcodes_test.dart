import 'package:famchat/chat/emoji/shortcodes.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// `|` marks the cursor.
TextEditingValue v(String marked) {
  final i = marked.indexOf('|');
  return TextEditingValue(text: marked.replaceFirst('|', ''), selection: TextSelection.collapsed(offset: i));
}

String show(TextEditingValue value) =>
    value.text.replaceRange(value.selection.baseOffset, value.selection.baseOffset, '|');

void main() {
  group('shortcode data', () {
    test('has the common GitHub/Slack names and aliases', () {
      expect(emojiForShortcode('+1'), '👍');
      expect(emojiForShortcode('thumbsup'), '👍');
      expect(emojiForShortcode('-1'), '👎');
      expect(emojiForShortcode('heart'), '❤️');
      expect(emojiForShortcode('joy'), '😂');
      expect(emojiForShortcode('smile'), '😄');
      expect(emojiForShortcode('fire'), '🔥');
      expect(emojiForShortcode('tada'), '🎉');
      expect(emojiForShortcode('Tada'), '🎉', reason: 'names are case-insensitive');
      expect(emojiForShortcode('not_an_emoji'), isNull);
    });
  });

  group('shortcodeQueryAt', () {
    test('finds a partial name of two or more characters before the cursor', () {
      final q = shortcodeQueryAt(v('hi :sm|'))!;
      expect((q.start, q.end, q.query), (3, 6, 'sm'));
      expect(shortcodeQueryAt(v(':fire|'))!.query, 'fire');
      expect(shortcodeQueryAt(v('ok\n:+1|'))!.query, '+1');
      expect(shortcodeQueryAt(v('(:th|'))!.query, 'th');
      expect(shortcodeQueryAt(v(':Thu|'))!.query, 'thu', reason: 'lowercased');
    });

    test('covers the rest of the word after the cursor', () {
      final q = shortcodeQueryAt(v('a :thu|mbs b'))!;
      expect((q.start, q.end, q.query), (2, 9, 'thu'));
    });

    test('needs at least two characters', () {
      expect(shortcodeQueryAt(v(':|')), isNull);
      expect(shortcodeQueryAt(v(':s|')), isNull);
    });

    test('does not trigger in URLs, times or mid-word', () {
      expect(shortcodeQueryAt(v('http://|')), isNull);
      expect(shortcodeQueryAt(v('see https://example.com|')), isNull);
      expect(shortcodeQueryAt(v('at 10:30|')), isNull);
      expect(shortcodeQueryAt(v('a:bc|')), isNull);
      expect(shortcodeQueryAt(v('mailto:sam|')), isNull);
      expect(shortcodeQueryAt(v('x::sm|')), isNull);
      expect(shortcodeQueryAt(v('https://x.com/:smile|')), isNull);
    });

    test('ends at whitespace or a closed name', () {
      expect(shortcodeQueryAt(v(':smile |')), isNull);
      expect(shortcodeQueryAt(v(':smile:|')), isNull);
    });

    test('only with a collapsed selection', () {
      const value = TextEditingValue(text: ':smile', selection: TextSelection(baseOffset: 0, extentOffset: 6));
      expect(shortcodeQueryAt(value), isNull);
    });
  });

  group('searchShortcodes', () {
    test('exact name first, then prefix matches, then the rest', () {
      final names = searchShortcodes('fire').map((m) => m.name).toList();
      expect(names.first, 'fire');
      expect(names, contains('fire_engine'));
      final heart = searchShortcodes('heart', limit: 50).map((m) => m.name).toList();
      expect(heart.first, 'heart');
      expect(heart.indexOf('heart_eyes'), lessThan(heart.indexOf('broken_heart')));
    });

    test('lists each emoji once and respects the limit', () {
      final thumbs = searchShortcodes('thumbs');
      expect(thumbs.map((m) => m.emoji).toSet().length, thumbs.length);
      expect(searchShortcodes('a', limit: 5), hasLength(5));
      expect(searchShortcodes('zzzzqqq'), isEmpty);
    });

    test('popular names lead the prefix matches', () {
      expect(searchShortcodes('ta').first.name, 'tada');
      expect(searchShortcodes('th').first.name, 'thumbsup');
      expect(searchShortcodes('he').first.name, 'heart');
      expect(searchShortcodes('jo').first.name, 'joy');
    });

    test('every popular name exists', () {
      for (final n in ['thumbsup', 'tada', 'hugs', 'birthday', 'sunny', 'see_no_evil', 'white_check_mark']) {
        expect(emojiForShortcode(n), isNotNull, reason: n);
      }
    });

    test('finds +1', () {
      expect(searchShortcodes('+1').first, const ShortcodeMatch('+1', '👍'));
    });
  });

  group('replaceShortcodeQuery', () {
    test('replaces the :partial with the emoji and moves the cursor after it', () {
      final value = v('hi :sm| there');
      final out = replaceShortcodeQuery(value, shortcodeQueryAt(value)!, '😄');
      expect(show(out), 'hi 😄| there');
    });

    test('replaces the whole word when the cursor is inside it', () {
      final value = v(':thu|mbsup');
      expect(show(replaceShortcodeQuery(value, shortcodeQueryAt(value)!, '👍')), '👍|');
    });
  });

  group('insertEmoji', () {
    test('inserts at the cursor', () {
      expect(show(insertEmoji(v('ab|cd'), '🎉')), 'ab🎉|cd');
    });

    test('replaces a selection', () {
      const value = TextEditingValue(text: 'hello world', selection: TextSelection(baseOffset: 6, extentOffset: 11));
      expect(show(insertEmoji(value, '🌍')), 'hello 🌍|');
    });

    test('appends when there is no selection yet', () {
      const value = TextEditingValue(text: 'hi ');
      expect(show(insertEmoji(value, '👋')), 'hi 👋|');
    });
  });

  group('deleteBackward', () {
    test('removes a whole emoji, a selection, or nothing at the start', () {
      expect(show(deleteBackward(v('hi 👨‍👩‍👧|!'))), 'hi |!');
      expect(show(deleteBackward(v('ab|'))), 'a|');
      expect(show(deleteBackward(v('|ab'))), '|ab');
      const sel = TextEditingValue(text: 'hello', selection: TextSelection(baseOffset: 1, extentOffset: 4));
      expect(show(deleteBackward(sel)), 'h|o');
      expect(show(deleteBackward(const TextEditingValue(text: 'x🎉'))), 'x|');
    });
  });

  group('completeShortcode (closing colon)', () {
    TextEditingValue? type(String before) {
      // `before` has the cursor; typing ':' there.
      final old = v(before);
      final at = old.selection.baseOffset;
      final next = TextEditingValue(
        text: old.text.replaceRange(at, at, ':'),
        selection: TextSelection.collapsed(offset: at + 1),
      );
      return completeShortcode(old, next);
    }

    test('replaces a known :name: as the closing colon is typed', () {
      expect(show(type(':thumbsup|')!), '👍|');
      expect(show(type('great :+1|')!), 'great 👍|');
      expect(show(type('so :joy| really')!), 'so 😂| really');
      expect(show(type('(:tada|')!), '(🎉|');
      expect(show(type(':Heart|')!), '❤️|');
    });

    test('leaves unknown names, URLs, times and mid-word colons alone', () {
      expect(type(':nope_not_real|'), isNull);
      expect(type('http|'), isNull);
      expect(type('10:30|'), isNull);
      expect(type('at 10:30|'), isNull);
      expect(type('a:b|'), isNull);
      expect(type('a:smile|'), isNull);
      expect(type('|'), isNull);
      expect(type(':|'), isNull);
    });

    test('the formatter only acts on a typed colon', () {
      const f = ShortcodeFormatter();
      final pasted = f.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(text: ':smile:', selection: TextSelection.collapsed(offset: 7)),
      );
      expect(pasted.text, ':smile:', reason: 'a paste stays as pasted');
      final typed = f.formatEditUpdate(
        v(':smile|'),
        const TextEditingValue(text: ':smile:', selection: TextSelection.collapsed(offset: 7)),
      );
      expect(typed.text, '😄');
    });
  });

  group('emojiOnlyCount', () {
    test('counts messages made only of emoji', () {
      expect(emojiOnlyCount('👍'), 1);
      expect(emojiOnlyCount('❤️'), 1);
      expect(emojiOnlyCount('🎉🎉 🎉'), 3);
      expect(emojiOnlyCount('👨‍👩‍👧‍👦'), 1, reason: 'a ZWJ family is one emoji');
      expect(emojiOnlyCount('👍🏽'), 1, reason: 'skin tone');
      expect(emojiOnlyCount('🇳🇿'), 1, reason: 'flag');
      expect(emojiOnlyCount(' 😂 '), 1);
    });

    test('is null for anything else', () {
      expect(emojiOnlyCount(''), isNull);
      expect(emojiOnlyCount('hi 👋'), isNull);
      expect(emojiOnlyCount('1'), isNull);
      expect(emojiOnlyCount('#'), isNull);
      expect(emojiOnlyCount('©'), isNull);
      expect(emojiOnlyCount(':)'), isNull);
    });
  });
}
