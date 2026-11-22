// Message text with tappable web links (http, https and bare www.).
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../chat/markdown.dart';
import '../chat/mentions.dart';
import '../session/invite_link.dart';

/// A run of text, and the link it opens if it is one.
typedef TextPart = ({String text, Uri? uri});

// A link may follow `_` and end before `_` or `~`, so Markdown marks around it (`_https://…_`) stay marks.
final _candidate = RegExp(r'(?<![\p{L}\p{N}.@/:-])(?:https?://|www\.)[^\s<>"]+', caseSensitive: false, unicode: true);
const _trailing = '.,:;!?\'"*_~';
const _pairs = {')': '(', ']': '[', '}': '{'};

/// [text] cut into plain runs and links, in order.
List<TextPart> splitLinks(String text) {
  final parts = <TextPart>[];
  var at = 0;
  for (final m in _candidate.allMatches(text)) {
    var link = m.group(0)!;
    // Trim trailing punctuation, and closing brackets that have no opening one inside the link.
    for (;;) {
      if (link.isEmpty) break;
      final last = link[link.length - 1];
      if (_trailing.contains(last)) {
        link = link.substring(0, link.length - 1);
      } else if (_pairs.containsKey(last) &&
          last.allMatches(link).length > _pairs[last]!.allMatches(link).length) {
        link = link.substring(0, link.length - 1);
      } else {
        break;
      }
    }
    final uri = Uri.tryParse(link.toLowerCase().startsWith('www.') ? 'https://$link' : link);
    if (uri == null || uri.host.isEmpty || !uri.host.contains('.')) continue;
    if (m.start > at) parts.add((text: text.substring(at, m.start), uri: null));
    parts.add((text: link, uri: uri));
    at = m.start + link.length;
  }
  if (at < text.length) parts.add((text: text.substring(at), uri: null));
  return parts;
}

/// Opens [uri] in the browser, or an invite link in the app itself.
Future<void> openLink(Uri uri) async {
  if (openInviteInApp(uri)) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank');
}

/// [text] in [style], with its links underlined and tappable, and `@name` of [mentions] in bold.
/// With [markdown], its Markdown (see chat/markdown.dart) shows as formatting.
class LinkText extends StatefulWidget {
  const LinkText(
    this.text, {
    super.key,
    this.style,
    this.linkColor,
    this.onOpen = openLink,
    this.mentions = const [],
    this.markdown = false,
  });

  final String text;
  final TextStyle? style;
  final bool markdown;

  /// Names whose `@name` stands out.
  final List<String> mentions;

  /// Defaults to the style's color.
  final Color? linkColor;
  final void Function(Uri uri) onOpen;

  @override
  State<LinkText> createState() => _LinkTextState();
}

class _LinkTextState extends State<LinkText> {
  /// Made when the text changes, not on every build: a rebuild while a link is pressed (a new
  /// message, a hover) must not dispose the recognizer handling the tap.
  List<({String text, Uri? uri, bool mention})> _parts = const [];
  final _recognizers = <TapGestureRecognizer>[];

  /// The text's blocks when it has Markdown to show; null for the plain path above.
  List<MdBlock>? _blocks;

  @override
  void initState() {
    super.initState();
    _split();
  }

  @override
  void didUpdateWidget(LinkText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text || old.markdown != widget.markdown || !_sameNames(old.mentions, widget.mentions)) {
      _split();
    }
  }

  static bool _sameNames(List<String> a, List<String> b) =>
      a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

  void _split() {
    _clear();
    _blocks = widget.markdown && hasMarkdown(widget.text) ? parseMarkdown(widget.text) : null;
    if (_blocks case final blocks?) {
      _parts = const [];
      // One recognizer per link, in the order build meets them.
      for (final b in blocks) {
        for (final s in _spansOf(b)) {
          if (s.uri case final uri?) _recognizers.add(TapGestureRecognizer()..onTap = () => widget.onOpen(uri));
        }
      }
      return;
    }
    _parts = [
      for (final p in splitLinks(widget.text))
        if (p.uri != null || widget.mentions.isEmpty)
          (text: p.text, uri: p.uri, mention: false)
        else
          ..._splitMentions(p.text),
    ];
    for (final p in _parts) {
      if (p.uri != null) _recognizers.add(TapGestureRecognizer()..onTap = () => widget.onOpen(p.uri!));
    }
  }

  List<({String text, Uri? uri, bool mention})> _splitMentions(String text) {
    final out = <({String text, Uri? uri, bool mention})>[];
    var at = 0;
    for (final (s, e) in mentionRanges(text, widget.mentions)) {
      if (s > at) out.add((text: text.substring(at, s), uri: null, mention: false));
      out.add((text: text.substring(s, e), uri: null, mention: true));
      at = e;
    }
    if (at < text.length) out.add((text: text.substring(at), uri: null, mention: false));
    return out;
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  void _clear() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  static List<MdSpan> _spansOf(MdBlock b) => switch (b) {
        MdParagraph(:final spans) || MdListItem(:final spans) || MdQuote(:final spans) => spans,
        MdCode() => const [],
      };

  TextStyle get _link => (widget.style ?? const TextStyle()).copyWith(
        color: widget.linkColor,
        decoration: TextDecoration.underline,
        decorationColor: widget.linkColor ?? widget.style?.color,
      );

  static const _mono = TextStyle(fontFamily: 'monospace', fontFamilyFallback: ['Menlo', 'Consolas', 'Courier New']);

  Color get _ink => widget.style?.color ?? DefaultTextStyle.of(context).style.color ?? const Color(0xFF000000);

  /// [spans] as text, taking link recognizers from [next] in order.
  Widget _rich(List<MdSpan> spans, Iterator<TapGestureRecognizer> next, {TextStyle? style}) {
    final children = <InlineSpan>[];
    for (final s in spans) {
      final look = TextStyle(
        fontWeight: s.bold ? FontWeight.w700 : null,
        fontStyle: s.italic ? FontStyle.italic : null,
        decoration: s.strike ? TextDecoration.lineThrough : null,
      );
      if (s.uri != null) {
        next.moveNext();
        children.add(TextSpan(
          text: s.text,
          style: _link.merge(look).copyWith(
                decoration: TextDecoration.combine([
                  TextDecoration.underline,
                  if (s.strike) TextDecoration.lineThrough,
                ]),
              ),
          mouseCursor: SystemMouseCursors.click,
          recognizer: next.current,
        ));
      } else if (s.code) {
        children.add(TextSpan(text: s.text, style: _mono.copyWith(backgroundColor: _ink.withValues(alpha: 0.12))));
      } else if (widget.mentions.isEmpty) {
        children.add(TextSpan(text: s.text, style: look));
      } else {
        for (final p in _splitMentions(s.text)) {
          children.add(TextSpan(text: p.text, style: p.mention ? look.copyWith(fontWeight: FontWeight.w700) : look));
        }
      }
    }
    return Text.rich(TextSpan(children: children), style: style ?? widget.style);
  }

  Widget _markdown(List<MdBlock> blocks) {
    final next = _recognizers.iterator;
    final ink = _ink;
    final fontSize = widget.style?.fontSize ?? DefaultTextStyle.of(context).style.fontSize ?? 14;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: 2,
      children: [
        for (final b in blocks)
          switch (b) {
            MdParagraph(:final spans) => _rich(spans, next),
            MdListItem(:final marker, :final depth, :final spans) => Padding(
                padding: EdgeInsets.only(left: depth * fontSize),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(minWidth: fontSize * 1.3),
                    child: Text(marker, style: widget.style),
                  ),
                  const SizedBox(width: 4),
                  Flexible(child: _rich(spans, next)),
                ]),
              ),
            MdQuote(:final spans) => Container(
                padding: const EdgeInsets.only(left: 8),
                decoration: BoxDecoration(border: Border(left: BorderSide(color: ink.withValues(alpha: 0.5), width: 3))),
                child: _rich(spans, next, style: widget.style?.copyWith(color: ink.withValues(alpha: 0.8))),
              ),
            MdCode(:final text) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(color: ink.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(6)),
                child: Text(text, style: (widget.style ?? const TextStyle()).merge(_mono).copyWith(fontSize: fontSize * 0.9)),
              ),
          },
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_blocks case final blocks?) return _markdown(blocks);
    if (_recognizers.isEmpty && !_parts.any((p) => p.mention)) return Text(widget.text, style: widget.style);
    final link = _link;
    var i = 0;
    return Text.rich(
      TextSpan(children: [
        for (final p in _parts)
          if (p.mention)
            TextSpan(text: p.text, style: const TextStyle(fontWeight: FontWeight.w700))
          else if (p.uri == null)
            TextSpan(text: p.text)
          else
            TextSpan(text: p.text, style: link, mouseCursor: SystemMouseCursors.click, recognizer: _recognizers[i++]),
      ]),
      style: widget.style,
    );
  }
}
