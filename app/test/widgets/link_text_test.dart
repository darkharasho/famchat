import 'package:famchat/widgets/link_text.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// [text] with each link wrapped in `[...]`, plus the URIs they open.
(String, String) marked(String text) {
  final out = StringBuffer();
  final uris = <String>[];
  for (final p in splitLinks(text)) {
    if (p.uri == null) {
      out.write(p.text);
    } else {
      out.write('[${p.text}]');
      uris.add(p.uri.toString());
    }
  }
  return (out.toString(), uris.join(' '));
}

void main() {
  test('finds web links and leaves the rest as text', () {
    expect(marked('see https://famchat.dev/support ok'), ('see [https://famchat.dev/support] ok', 'https://famchat.dev/support'));
    expect(marked('http://a.io'), ('[http://a.io]', 'http://a.io'));
    expect(marked('www.example.com/x?y=1#z'), ('[www.example.com/x?y=1#z]', 'https://www.example.com/x?y=1#z'));
    expect(marked('no links here'), ('no links here', ''));
    expect(marked(''), ('', ''));
  });

  test('trailing punctuation stays outside the link; balanced brackets stay in', () {
    expect(marked('look: https://a.io/x.'), ('look: [https://a.io/x].', 'https://a.io/x'));
    expect(marked('(https://a.io/x)'), ('([https://a.io/x])', 'https://a.io/x'));
    expect(marked('https://en.wikipedia.org/wiki/Foo_(bar), nice'),
        ('[https://en.wikipedia.org/wiki/Foo_(bar)], nice', 'https://en.wikipedia.org/wiki/Foo_(bar)'));
    expect(marked('https://a.io/?q=1!'), ('[https://a.io/?q=1]!', 'https://a.io/?q=1'));
  });

  test('several links, and only web schemes', () {
    expect(marked('a https://x.io b www.y.org'), ('a [https://x.io] b [www.y.org]', 'https://x.io https://www.y.org'));
    expect(marked('javascript:alert(1) ftp://x.io file:///etc'), ('javascript:alert(1) ftp://x.io file:///etc', ''));
    expect(marked('https://'), ('https://', ''));
    expect(marked('xwww.a.io'), ('xwww.a.io', ''));
  });

  testWidgets('tapping a link opens it', (tester) async {
    final opened = <Uri>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: LinkText('go to https://famchat.dev now', onOpen: opened.add)),
    ));
    final rich = tester.widget<RichText>(find.byType(RichText).first);
    TapGestureRecognizer? tap;
    rich.text.visitChildren((span) {
      if (span is TextSpan && span.recognizer is TapGestureRecognizer) tap = span.recognizer! as TapGestureRecognizer;
      return true;
    });
    tap!.onTap!();
    expect(opened, [Uri.parse('https://famchat.dev')]);
  });
}
