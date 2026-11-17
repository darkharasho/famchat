// A small English spell checker for desktop and the web, where Flutter has no system one. Phones
// use the platform's own checker instead.

/// Checks words against a word list and suggests corrections by edit distance.
class Speller {
  Speller(Iterable<String> words) {
    for (final w in words) {
      if (w.isEmpty) continue;
      final lower = w.toLowerCase();
      // Prefer the lowercase spelling when a word is listed both ways ("May", "may").
      if (!_words.containsKey(lower) || w == lower) _words[lower] = w;
    }
  }

  /// Lowercase word → how the list spells it.
  final _words = <String, String>{};

  static final _letters = RegExp(r"[A-Za-z][A-Za-z']*");
  static final _token = RegExp(r'\S+');
  static const _alphabet = "abcdefghijklmnopqrstuvwxyz'";

  bool isKnown(String word) {
    final lower = word.toLowerCase();
    if (_words.containsKey(lower)) return true;
    // Possessives: "Grandma's" when "grandma" is known.
    return lower.endsWith("'s") && _words.containsKey(lower.substring(0, lower.length - 2));
  }

  /// The ranges of misspelled words in [text], as (start, end). Skips links, @mentions,
  /// :shortcodes:, anything with digits, acronyms (all capitals), single letters, words [known]
  /// accepts (given lowercase), and the last word while it's still being typed.
  List<(int, int)> misspellings(String text, {bool Function(String lower)? known}) {
    final out = <(int, int)>[];
    for (final t in _token.allMatches(text)) {
      if (t.end == text.length) break; // still being typed
      final token = t.group(0)!;
      if (token.contains('://') ||
          token.startsWith('www.') ||
          token.startsWith('@') ||
          token.startsWith(':') ||
          token.contains(RegExp(r'[0-9@/\\_#]')) ||
          RegExp(r'[A-Za-z]\.[A-Za-z]').hasMatch(token)) {
        continue;
      }
      for (final m in _letters.allMatches(token)) {
        var word = m.group(0)!;
        while (word.endsWith("'")) {
          word = word.substring(0, word.length - 1);
        }
        if (word.length < 2 || word == word.toUpperCase()) continue;
        if (isKnown(word) || (known?.call(word.toLowerCase()) ?? false)) continue;
        final start = t.start + m.start;
        out.add((start, start + word.length));
      }
    }
    return out;
  }

  /// Up to [max] corrections for [word], likeliest first, capitalized like [word].
  List<String> suggest(String word, {int max = 5}) {
    final lower = word.toLowerCase();
    final scored = <String, int>{};
    void consider(Iterable<(String, int)> candidates, int distance) {
      for (final (c, bonus) in candidates) {
        if (c == lower || !_words.containsKey(c)) continue;
        // Distance first; then transpositions, keeping the first letter, and similar length.
        var score = distance * 100 - bonus;
        if (c.isNotEmpty && lower.isNotEmpty && c[0] != lower[0]) score += 20;
        score += (c.length - lower.length).abs() * 5;
        final prev = scored[c];
        if (prev == null || score < prev) scored[c] = score;
      }
    }

    final first = _edits(lower).toList();
    consider(first, 1);
    if (scored.length < max && lower.length <= 14) {
      for (final (e, _) in first) {
        consider(_edits(e).map((x) => (x.$1, 0)), 2);
      }
    }
    final ranked = scored.keys.toList()
      ..sort((a, b) {
        final byScore = scored[a]!.compareTo(scored[b]!);
        return byScore != 0 ? byScore : a.compareTo(b);
      });
    final capital = word.isNotEmpty && word[0] != word[0].toLowerCase();
    return [
      for (final c in ranked.take(max))
        capital ? '${_words[c]![0].toUpperCase()}${_words[c]!.substring(1)}' : _words[c]!,
    ];
  }

  /// Every string one edit from [w], with a bonus for the likeliest kinds of slip.
  static Iterable<(String, int)> _edits(String w) sync* {
    for (var i = 0; i < w.length - 1; i++) {
      yield ('${w.substring(0, i)}${w[i + 1]}${w[i]}${w.substring(i + 2)}', 15); // transposed
    }
    for (var i = 0; i < w.length; i++) {
      yield ('${w.substring(0, i)}${w.substring(i + 1)}', 0); // deleted
      for (final c in _alphabet.split('')) {
        yield ('${w.substring(0, i)}$c${w.substring(i + 1)}', 5); // replaced
      }
    }
    for (var i = 0; i <= w.length; i++) {
      for (final c in _alphabet.split('')) {
        yield ('${w.substring(0, i)}$c${w.substring(i)}', 0); // inserted
      }
    }
  }
}
