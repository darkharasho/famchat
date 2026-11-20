// The bit of Markdown a chat message understands: **bold**, *italic* or _italic_, ~~strike~~,
// `code`, ``` code blocks ```, "- " bullets, "1. " numbered items and "> " quotes. Web links are
// never cut by it (an `_` inside a URL stays in the URL), and a backslash shows the next mark as is.
//
// Marks only count at word edges, so snake_case, 2*3*4 and file_name_here stay plain text.
import '../widgets/link_text.dart' show splitLinks;

/// A run of message text with one look.
class MdSpan {
  const MdSpan(this.text, {this.uri, this.bold = false, this.italic = false, this.strike = false, this.code = false});

  final String text;

  /// The web link this run opens, if it is one.
  final Uri? uri;
  final bool bold, italic, strike, code;

  bool get plain => uri == null && !bold && !italic && !strike && !code;

  @override
  bool operator ==(Object other) =>
      other is MdSpan &&
      other.text == text &&
      other.uri == uri &&
      other.bold == bold &&
      other.italic == italic &&
      other.strike == strike &&
      other.code == code;

  @override
  int get hashCode => Object.hash(text, uri, bold, italic, strike, code);

  @override
  String toString() {
    final marks = [if (bold) 'b', if (italic) 'i', if (strike) 's', if (code) 'c', if (uri != null) 'link'].join();
    return '$marks"$text"';
  }
}

/// A block of a message: lines of text, a list item, a quote or a code block.
sealed class MdBlock {
  const MdBlock();
}

/// Ordinary lines (joined with `\n`).
class MdParagraph extends MdBlock {
  const MdParagraph(this.spans);
  final List<MdSpan> spans;
}

/// One "- " or "1. " item. [marker] is "•" or the number with its dot ("1."); [depth] counts
/// levels of indent (two spaces or a tab each).
class MdListItem extends MdBlock {
  const MdListItem(this.marker, this.depth, this.spans);
  final String marker;
  final int depth;
  final List<MdSpan> spans;
}

/// "> " lines.
class MdQuote extends MdBlock {
  const MdQuote(this.spans);
  final List<MdSpan> spans;
}

/// The lines between ``` fences, as typed.
class MdCode extends MdBlock {
  const MdCode(this.text);
  final String text;
}

final _bullet = RegExp(r'^([ \t]*)[-*+•] +(.*)$');
final _numbered = RegExp(r'^([ \t]*)(\d{1,3})[.)] +(.*)$');
final _quote = RegExp(r'^> ?(.*)$');
final _fence = RegExp(r'^ {0,3}```');

int _depth(String indent) {
  var cols = 0;
  for (final c in indent.codeUnits) {
    cols += c == 0x09 ? 2 : 1;
  }
  return (cols ~/ 2).clamp(0, 4);
}

/// [text] as blocks. Text with no list, quote or code block is one [MdParagraph].
List<MdBlock> parseMarkdown(String text) {
  final blocks = <MdBlock>[];
  final para = <String>[];
  final quote = <String>[];
  void flushPara() {
    if (para.isNotEmpty) blocks.add(MdParagraph(parseInline(para.join('\n'))));
    para.clear();
  }

  void flushQuote() {
    if (quote.isNotEmpty) blocks.add(MdQuote(parseInline(quote.join('\n'))));
    quote.clear();
  }

  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (_fence.hasMatch(line)) {
      // A fence with no closing one is just text.
      final close = lines.indexWhere(_fence.hasMatch, i + 1);
      if (close != -1) {
        flushPara();
        flushQuote();
        blocks.add(MdCode(lines.sublist(i + 1, close).join('\n')));
        i = close;
        continue;
      }
    }
    if (_quote.firstMatch(line) case final m?) {
      flushPara();
      quote.add(m.group(1)!);
      continue;
    }
    flushQuote();
    if (_bullet.firstMatch(line) case final m? when m.group(2)!.trim().isNotEmpty) {
      flushPara();
      blocks.add(MdListItem('•', _depth(m.group(1)!), parseInline(m.group(2)!)));
    } else if (_numbered.firstMatch(line) case final m? when m.group(3)!.trim().isNotEmpty) {
      flushPara();
      blocks.add(MdListItem('${m.group(2)}.', _depth(m.group(1)!), parseInline(m.group(3)!)));
    } else {
      para.add(line);
    }
  }
  flushPara();
  flushQuote();
  return blocks;
}

/// Whether [text] uses any formatting [parseMarkdown] understands.
bool hasMarkdown(String text) {
  final blocks = parseMarkdown(text);
  if (blocks.length != 1) return true;
  final only = blocks.single;
  return only is! MdParagraph || only.spans.any((s) => s.bold || s.italic || s.strike || s.code) || _hasEscape(text);
}

bool _hasEscape(String text) => RegExp(r'\\[\\`*_~>#+\-.]').hasMatch(text);

/// [text] without its formatting marks, for one-line previews and notifications: bullets
/// become "• ", the marks around words go, and links and everything else stay.
String stripMarkdown(String text) {
  if (!hasMarkdown(text)) return text;
  String run(List<MdSpan> spans) => spans.map((s) => s.text).join();
  return [
    for (final b in parseMarkdown(text))
      switch (b) {
        MdParagraph(:final spans) => run(spans),
        MdListItem(:final marker, :final spans) => '$marker ${run(spans)}',
        MdQuote(:final spans) => run(spans),
        MdCode(:final text) => text,
      },
  ].join('\n');
}

// ---- Inline marks ----

const _escapable = r'\`*_~>#+-.!()[]{}|';
final _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);
final _space = RegExp(r'\s');

bool _isWord(String s, int i) => i >= 0 && i < s.length && _wordChar.hasMatch(s[i]);
bool _isSpace(String s, int i) => i < 0 || i >= s.length || _space.hasMatch(s[i]);

typedef _Style = ({bool bold, bool italic, bool strike});

/// One paragraph's [text] as styled runs, links included.
List<MdSpan> parseInline(String text) {
  // Where the links are, so no mark is looked for inside one.
  final links = <(int, int, Uri)>[];
  var at = 0;
  for (final p in splitLinks(text)) {
    if (p.uri != null) links.add((at, at + p.text.length, p.uri!));
    at += p.text.length;
  }
  final out = <MdSpan>[];
  _Parser(text, links, out).run(0, text.length, (bold: false, italic: false, strike: false));
  // Neighbouring runs with the same look become one.
  final merged = <MdSpan>[];
  for (final s in out) {
    if (s.text.isEmpty) continue;
    final last = merged.isEmpty ? null : merged.last;
    if (last != null &&
        last.uri == null &&
        s.uri == null &&
        last.bold == s.bold &&
        last.italic == s.italic &&
        last.strike == s.strike &&
        last.code == s.code) {
      merged[merged.length - 1] =
          MdSpan(last.text + s.text, bold: s.bold, italic: s.italic, strike: s.strike, code: s.code);
    } else {
      merged.add(s);
    }
  }
  return merged;
}

class _Parser {
  _Parser(this.text, this.links, this.out);

  final String text;
  final List<(int, int, Uri)> links;
  final List<MdSpan> out;

  (int, int, Uri)? _linkAt(int i) {
    for (final l in links) {
      if (l.$1 == i) return l;
    }
    return null;
  }

  bool _inLink(int i) => links.any((l) => i >= l.$1 && i < l.$2);

  /// Parses text[start, end) with [style].
  void run(int start, int end, _Style style) {
    final buf = StringBuffer();
    void flush() {
      if (buf.isEmpty) return;
      out.add(MdSpan(buf.toString(), bold: style.bold, italic: style.italic, strike: style.strike));
      buf.clear();
    }

    var i = start;
    outer:
    while (i < end) {
      if (_linkAt(i) case final l?) {
        flush();
        final stop = l.$2 < end ? l.$2 : end;
        out.add(MdSpan(text.substring(i, stop),
            uri: l.$3, bold: style.bold, italic: style.italic, strike: style.strike));
        i = stop;
        continue;
      }
      final c = text[i];
      if (c == r'\' && i + 1 < end && _escapable.contains(text[i + 1])) {
        buf.write(text[i + 1]);
        i += 2;
        continue;
      }
      if (c == '`') {
        final close = text.indexOf('`', i + 1);
        if (close != -1 && close < end && close > i + 1) {
          flush();
          out.add(MdSpan(text.substring(i + 1, close), code: true));
          i = close + 1;
          continue;
        }
      }
      for (final d in const ['**', '__', '~~', '*', '_']) {
        if (!text.startsWith(d, i) || !_canOpen(i, d)) continue;
        final close = _findClose(i + d.length, end, d);
        if (close == -1) continue;
        flush();
        run(i + d.length, close, (
          bold: style.bold || d == '**' || d == '__',
          italic: style.italic || d == '*' || d == '_',
          strike: style.strike || d == '~~',
        ));
        i = close + d.length;
        continue outer;
      }
      buf.write(c);
      i++;
    }
    flush();
  }

  /// An opening mark: at a word's start (not after a letter or digit), and followed by text.
  bool _canOpen(int i, String d) {
    final after = i + d.length;
    if (_isWord(text, i - 1) || _isSpace(text, after)) return false;
    // "*" right before another "*" is part of "**" that had no close.
    if (d.length == 1 && after < text.length && text[after] == d) return false;
    return true;
  }

  /// The closing [d] for content starting at [from], before [end] and on the same line; -1 if none.
  int _findClose(int from, int end, String d) {
    for (var k = from + 1; k + d.length <= end; k++) {
      if (text[k] == '\n') return -1;
      if (text[k] == r'\' && k + 1 < end) {
        k++;
        continue;
      }
      if (!text.startsWith(d, k) || _inLink(k)) continue;
      if (_isSpace(text, k - 1) || _isWord(text, k + d.length)) continue;
      if (d.length == 1 && (text[k - 1] == d || (k + 1 < text.length && text[k + 1] == d))) continue;
      return k;
    }
    return -1;
  }
}
