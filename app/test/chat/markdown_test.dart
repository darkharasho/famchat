import 'package:famchat/chat/markdown.dart';
import 'package:flutter_test/flutter_test.dart';

/// [parseInline] as a compact string: each run is its marks then its quoted text.
String inline(String text) => parseInline(text).join(' ');

void main() {
  test('bold, italic, strike and code', () {
    expect(inline('a **b** c'), '"a " b"b" " c"');
    expect(inline('a __b__ c'), '"a " b"b" " c"');
    expect(inline('_this_ and *that*'), 'i"this" " and " i"that"');
    expect(inline('~~gone~~'), 's"gone"');
    expect(inline('run `ls -la` now'), '"run " c"ls -la" " now"');
    expect(inline('**bold _and italic_**'), 'b"bold " bi"and italic"');
  });

  test('marks inside words and unmatched marks stay as typed', () {
    expect(inline('snake_case_name'), '"snake_case_name"');
    expect(inline('2*3*4 = 24'), '"2*3*4 = 24"');
    expect(inline('a * b * c'), '"a * b * c"');
    expect(inline('**not closed'), '"**not closed"');
    expect(inline('_ spaced _'), '"_ spaced _"');
    expect(inline('``'), '"``"');
    expect(inline('*one\ntwo*'), '"*one\ntwo*"');
  });

  test('a backslash shows a mark as is', () {
    expect(inline(r'\*not italic\*'), '"*not italic*"');
    expect(inline(r'a\b'), r'"a\b"');
  });

  test('links are never cut by marks, and can be styled', () {
    final spans = parseInline('see https://a.io/x_y_z ok');
    expect(spans.map((s) => s.text), ['see ', 'https://a.io/x_y_z', ' ok']);
    expect(spans[1].uri, Uri.parse('https://a.io/x_y_z'));
    final bold = parseInline('**https://a.io**');
    expect(bold.single.bold, isTrue);
    expect(bold.single.uri, Uri.parse('https://a.io'));
    final italic = parseInline('_https://a.io/b_ c');
    expect(italic.first.italic, isTrue);
    expect(italic.first.uri, Uri.parse('https://a.io/b'));
  });

  test('lists, quotes and code blocks', () {
    final blocks = parseMarkdown('Shopping:\n- milk\n- **eggs**\n  - brown\n1. first\n2) second\n> said\n> this\nend');
    expect(blocks.map((b) => b.runtimeType.toString()), [
      'MdParagraph', 'MdListItem', 'MdListItem', 'MdListItem', 'MdListItem', 'MdListItem', 'MdQuote', 'MdParagraph',
    ]);
    final items = blocks.whereType<MdListItem>().toList();
    expect(items.map((i) => (i.marker, i.depth)), [('•', 0), ('•', 0), ('•', 1), ('1.', 0), ('2.', 0)]);
    expect(items[1].spans.single.bold, isTrue);
    expect((blocks[6] as MdQuote).spans.single.text, 'said\nthis');

    final code = parseMarkdown('look:\n```\nfoo **bar**\n  baz\n```\nok');
    expect((code[1] as MdCode).text, 'foo **bar**\n  baz');
    expect((code[2] as MdParagraph).spans.single.text, 'ok');
  });

  test('plain text is one paragraph; a lone fence or dash is text', () {
    expect(hasMarkdown('hello there\nhow are you?'), isFalse);
    expect(hasMarkdown('-'), isFalse);
    expect(hasMarkdown('- '), isFalse);
    expect(hasMarkdown('```\nnot closed'), isFalse);
    expect(hasMarkdown('-5 degrees'), isFalse);
    expect(hasMarkdown('**hi**'), isTrue);
    expect(hasMarkdown('- one'), isTrue);
  });

  test('stripMarkdown leaves readable text for previews', () {
    expect(stripMarkdown('**Dinner** at _6_'), 'Dinner at 6');
    expect(stripMarkdown('List:\n- a\n- b'), 'List:\n• a\n• b');
    expect(stripMarkdown('plain'), 'plain');
    expect(stripMarkdown(r'\*star\*'), '*star*');
  });
}
