import 'package:famchat/chat/mentions.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

TextEditingValue at(String text, [int? cursor]) =>
    TextEditingValue(text: text, selection: TextSelection.collapsed(offset: cursor ?? text.length));

void main() {
  const people = {'u1': 'Mom', 'u2': 'Ann', 'u3': 'Anna Lee', 'u4': 'Bo'};

  test('mentionsIn finds @name followed by a word boundary, longest names first', () {
    expect(mentionsIn('@Mom can you?', people), ['u1']);
    expect(mentionsIn('hey @anna lee and @Ann!', people), unorderedEquals(['u3', 'u2']));
    expect(mentionsIn('@Annabel is not Ann', people), isEmpty);
    expect(mentionsIn('email me@Mom.com', people), isEmpty, reason: 'not after a letter');
    expect(mentionsIn('@Bo @Bo', people), ['u4']);
    expect(mentionsIn('no mentions', people), isEmpty);
  });

  test('mentionQueryAt: the @word being typed at the cursor', () {
    expect(mentionQueryAt(at('hi @mo')), (start: 3, query: 'mo'));
    expect(mentionQueryAt(at('@')), (start: 0, query: ''));
    expect(mentionQueryAt(at('a@b')), isNull, reason: 'an email, not a mention');
    expect(mentionQueryAt(at('@mom hi')), isNull, reason: 'the cursor moved on');
    expect(mentionQueryAt(at('@mo and', 3)), (start: 0, query: 'mo'));
    expect(mentionQueryAt(const TextEditingValue(text: '@x')), isNull, reason: 'no cursor');
  });

  test('matchingPeople: by the start of the name or of any word in it', () {
    expect(matchingPeople('an', people).map((p) => p.id), ['u2', 'u3']);
    expect(matchingPeople('lee', people).map((p) => p.id), ['u3']);
    expect(matchingPeople('', people).length, 4);
    expect(matchingPeople('z', people), isEmpty);
  });

  test('insertMention replaces the query with @Name and a space', () {
    final v = insertMention(at('ask @an please', 7), (start: 4, query: 'an'), 'Anna Lee');
    expect(v.text, 'ask @Anna Lee please');
    expect(v.selection.baseOffset, 'ask @Anna Lee '.length);
    final end = insertMention(at('@m'), (start: 0, query: 'm'), 'Mom');
    expect(end.text, '@Mom ');
  });

  test('mention ranges for highlighting', () {
    expect(mentionRanges('@Mom and @Anna Lee', ['Mom', 'Anna Lee']), [(0, 4), (9, 18)]);
    expect(mentionRanges('@Momma', ['Mom']), isEmpty);
  });

  test('texts carry mentions', () {
    const t = TextBody('@Mom hi', mentions: ['u1']);
    expect(Plaintext.decode(t.encode()).toJson(), t.toJson());
    expect((Plaintext.decode(t.encode()) as TextBody).mentions, ['u1']);
    expect(const TextBody('hi').toJson().containsKey('mentions'), isFalse);
    expect((Plaintext.decode(const TextBody('hi').encode()) as TextBody).mentions, isEmpty);
    expect(() => Plaintext.decode('{"kind":"text","text":"a","mentions":"u1"}'.codeUnits), throwsFormatException);
    expect(() => Plaintext.decode('{"kind":"text","text":"a","mentions":[1]}'.codeUnits), throwsFormatException);
  });
}
