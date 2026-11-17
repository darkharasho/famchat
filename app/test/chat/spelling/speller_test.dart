import 'dart:io';

import 'package:famchat/chat/spelling/speller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final speller = Speller(File('assets/spelling/en_US.txt').readAsLinesSync());

  test('knows words in any case, with apostrophes', () {
    expect(speller.isKnown('running'), isTrue);
    expect(speller.isKnown('Running'), isTrue);
    expect(speller.isKnown("don't"), isTrue);
    expect(speller.isKnown('recieve'), isFalse);
  });

  test('suggests the likely word first, keeping a leading capital', () {
    expect(speller.suggest('recieve').first, 'receive');
    expect(speller.suggest('teh'), contains('the'));
    expect(speller.suggest('Recieve').first, 'Receive');
    expect(speller.suggest('definately'), contains('definitely'));
    expect(speller.suggest('recieve').length, lessThanOrEqualTo(5));
  });

  test('flags misspelled words with their ranges', () {
    expect(speller.misspellings('i recieve it'), [(2, 9)]);
  });

  test('leaves links, mentions, shortcodes, acronyms, numbers and extra words alone', () {
    const text = 'see https://exmple.com/xyzzy @Grandmaa :thumbsupp: NASAX 3rd 10am Zorblax ok';
    expect(speller.misspellings(text, known: (w) => w == 'zorblax'), isEmpty);
  });

  test('a word being typed at the end is not flagged until it is finished', () {
    expect(speller.misspellings('hello wor'), isEmpty);
    expect(speller.misspellings('hello wor '), [(6, 9)]);
  });
}
