import 'package:famchat/chat/emoji/emoticons.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// `¦` marks the cursor (`|` is part of emoticons like `:|`).
TextEditingValue v(String marked) {
  final i = marked.indexOf('¦');
  return TextEditingValue(
    text: marked.replaceFirst('¦', ''),
    selection: TextSelection.collapsed(offset: i),
  );
}

String show(TextEditingValue value) =>
    value.text.replaceRange(value.selection.baseOffset, value.selection.baseOffset, '¦');

void main() {
  group('completeEmoticon (typing a space or newline after it)', () {
    TextEditingValue? type(String before, [String ch = ' ']) {
      final old = v(before);
      final at = old.selection.baseOffset;
      final next = TextEditingValue(
        text: old.text.replaceRange(at, at, ch),
        selection: TextSelection.collapsed(offset: at + ch.length),
      );
      return completeEmoticon(old, next);
    }

    test('replaces a standalone emoticon, keeping the space', () {
      expect(show(type('<3¦')!), '❤️ ¦');
      expect(show(type('love you <3¦')!), 'love you ❤️ ¦');
      expect(show(type('hmm :|¦')!), 'hmm 😐 ¦');
      expect(show(type(':)¦ later')!), '🙂 ¦ later');
      expect(show(type('ok :-)¦')!), 'ok 🙂 ¦');
      expect(show(type(':D¦')!), '😃 ¦');
      expect(show(type(';)¦')!), '😉 ¦');
      expect(show(type(":'(¦")!), '😢 ¦');
      expect(show(type('XD¦')!), '😆 ¦');
      expect(show(type('</3¦')!), '💔 ¦');
      expect(show(type('nice :)¦', '\n')!), 'nice 🙂\n¦');
    });

    test('leaves text that only contains an emoticon alone', () {
      expect(type('http://¦'), isNull, reason: 'URLs');
      expect(type('see http:/¦'), isNull);
      expect(type('a<3¦'), isNull, reason: 'mid-word');
      expect(type('(:)¦'), isNull);
      expect(type('10:30¦'), isNull);
      expect(type('hello¦'), isNull);
      expect(type('¦'), isNull);
    });

    test('only reacts to a single typed space, not pastes or deletions', () {
      final old = v('<3¦');
      final pasted = TextEditingValue(text: '<3 and more', selection: const TextSelection.collapsed(offset: 11));
      expect(completeEmoticon(old, pasted), isNull);
      expect(completeEmoticon(v('<3 ¦'), v('<3¦')), isNull);
      expect(type('<3¦', 'x'), isNull);
    });
  });

  group('replaceTrailingEmoticon (on send)', () {
    test('converts an emoticon at the end of the message', () {
      expect(replaceTrailingEmoticon('love you <3'), 'love you ❤️');
      expect(replaceTrailingEmoticon(':|'), '😐');
      expect(replaceTrailingEmoticon('ok\n:P'), 'ok\n😛');
    });

    test('leaves everything else as typed', () {
      expect(replaceTrailingEmoticon('go to http://'), 'go to http://');
      expect(replaceTrailingEmoticon('a<3'), 'a<3');
      expect(replaceTrailingEmoticon('hello'), 'hello');
      expect(replaceTrailingEmoticon(''), '');
    });
  });
}
