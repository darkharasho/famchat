import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import 'speller.dart';

/// Desktop and the web have no system spell checker Flutter can use, so they check against the
/// bundled word list. Phones use the platform's own.
bool get usesWordListSpelling =>
    kIsWeb || {TargetPlatform.linux, TargetPlatform.macOS, TargetPlatform.windows}.contains(defaultTargetPlatform);

/// The bundled English word list, loaded the first time a composer needs it.
final spellerProvider = FutureProvider<Speller>((ref) async {
  // Decoded here: loadString hands big files to an isolate, which costs more than it saves.
  final data = await rootBundle.load('assets/spelling/en_US.txt');
  return Speller(const LineSplitter().convert(utf8.decode(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes))));
});

/// Words this user added to their dictionary (lowercase), kept on this device.
final userWordsProvider = AsyncNotifierProvider<UserWords, Set<String>>(UserWords.new);

class UserWords extends AsyncNotifier<Set<String>> {
  static const _key = 'spelling.words';

  @override
  Future<Set<String>> build() async {
    final raw = await ref.watch(chatDbProvider).metaValue(_key);
    if (raw == null) return <String>{};
    return {for (final w in jsonDecode(raw) as List) (w as String).toLowerCase()};
  }

  Future<void> add(String word) async {
    final words = {...(state.value ?? const <String>{}), word.toLowerCase()};
    state = AsyncData(words);
    await ref.read(chatDbProvider).setMeta(_key, jsonEncode(words.toList()..sort()));
  }
}

/// Spell checking against [speller], treating whatever [known] accepts (lowercase) as correct.
class WordListSpellCheckService extends SpellCheckService {
  WordListSpellCheckService(this.speller, this.known);

  final Speller speller;
  final bool Function(String lower) known;

  @override
  Future<List<SuggestionSpan>?> fetchSpellCheckSuggestions(Locale locale, String text) async => [
        for (final (start, end) in speller.misspellings(text, known: known))
          SuggestionSpan(TextRange(start: start, end: end), const []),
      ];
}
