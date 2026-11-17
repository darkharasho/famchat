// Text emoticons such as `<3` and `:|`, turned into emoji as they're typed.
import 'package:flutter/services.dart';

/// Emoticon → emoji. Matched exactly (case matters: `:P` and `:p` are both listed).
const emoticons = <String, String>{
  '<3': '❤️',
  '</3': '💔',
  ':)': '🙂',
  ':-)': '🙂',
  '(:': '🙂',
  ':(': '🙁',
  ':-(': '🙁',
  ':D': '😃',
  ':-D': '😃',
  'XD': '😆',
  'xD': '😆',
  ';)': '😉',
  ';-)': '😉',
  ':P': '😛',
  ':p': '😛',
  ':-P': '😛',
  ':-p': '😛',
  ';P': '😜',
  ';p': '😜',
  ':O': '😮',
  ':o': '😮',
  ':-O': '😮',
  ':-o': '😮',
  ':|': '😐',
  ':-|': '😐',
  ':/': '😕',
  ':-/': '😕',
  ':\\': '😕',
  ":'(": '😢',
  ":')": '🥲',
  ':*': '😘',
  ':-*': '😘',
  'B)': '😎',
  'B-)': '😎',
  '>:(': '😠',
  ':\$': '😳',
  'O:)': '😇',
  '^_^': '😊',
  '-_-': '😑',
  'T_T': '😭',
  ':3': '😺',
};

/// The whitespace-free run of text ending at [end], when it starts the text or follows whitespace.
final _lastWord = RegExp(r'(?:^|(?<=\s))\S+$');

/// When [next] is [old] with one space or newline typed at the cursor right after a standalone
/// emoticon, [next] with the emoticon replaced by its emoji; otherwise null.
TextEditingValue? completeEmoticon(TextEditingValue old, TextEditingValue next) {
  final sel = next.selection;
  if (!sel.isValid || !sel.isCollapsed || sel.baseOffset < 2) return null;
  final cursor = sel.baseOffset;
  final typedSpace = next.text.length == old.text.length + 1 &&
      (next.text[cursor - 1] == ' ' || next.text[cursor - 1] == '\n') &&
      next.text.replaceRange(cursor - 1, cursor, '') == old.text;
  if (!typedSpace) return null;
  final m = _lastWord.firstMatch(next.text.substring(0, cursor - 1));
  final emoji = m == null ? null : emoticons[m.group(0)];
  if (m == null || emoji == null) return null;
  return TextEditingValue(
    text: next.text.replaceRange(m.start, m.end, emoji),
    selection: TextSelection.collapsed(offset: cursor - m.group(0)!.length + emoji.length),
  );
}

/// [text] with a standalone emoticon at its very end replaced by its emoji (used when sending, since
/// no space follows the last word).
String replaceTrailingEmoticon(String text) {
  final m = _lastWord.firstMatch(text);
  final emoji = m == null ? null : emoticons[m.group(0)];
  return m == null || emoji == null ? text : text.replaceRange(m.start, m.end, emoji);
}

/// Turns a standalone emoticon into its emoji as the following space is typed (pastes are left alone).
class EmoticonFormatter extends TextInputFormatter {
  const EmoticonFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      completeEmoticon(oldValue, newValue) ?? newValue;
}
