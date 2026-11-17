// Message text with tappable web links (http, https and bare www.).
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

/// A run of text, and the link it opens if it is one.
typedef TextPart = ({String text, Uri? uri});

final _candidate = RegExp(r'(?<![\w.@/:-])(?:https?://|www\.)[^\s<>"]+', caseSensitive: false);
const _trailing = '.,:;!?\'"*';
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

Future<void> openLink(Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank');

/// [text] in [style], with its links underlined and tappable.
class LinkText extends StatefulWidget {
  const LinkText(this.text, {super.key, this.style, this.linkColor, this.onOpen = openLink});

  final String text;
  final TextStyle? style;

  /// Defaults to the style's color.
  final Color? linkColor;
  final void Function(Uri uri) onOpen;

  @override
  State<LinkText> createState() => _LinkTextState();
}

class _LinkTextState extends State<LinkText> {
  /// Made when the text changes, not on every build: a rebuild while a link is pressed (a new
  /// message, a hover) must not dispose the recognizer handling the tap.
  List<TextPart> _parts = const [];
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void initState() {
    super.initState();
    _split();
  }

  @override
  void didUpdateWidget(LinkText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _split();
  }

  void _split() {
    _clear();
    _parts = splitLinks(widget.text);
    for (final p in _parts) {
      if (p.uri != null) _recognizers.add(TapGestureRecognizer()..onTap = () => widget.onOpen(p.uri!));
    }
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

  @override
  Widget build(BuildContext context) {
    if (_recognizers.isEmpty) return Text(widget.text, style: widget.style);
    final link = (widget.style ?? const TextStyle()).copyWith(
      color: widget.linkColor,
      decoration: TextDecoration.underline,
      decorationColor: widget.linkColor ?? widget.style?.color,
    );
    var i = 0;
    return Text.rich(
      TextSpan(children: [
        for (final p in _parts)
          if (p.uri == null)
            TextSpan(text: p.text)
          else
            TextSpan(text: p.text, style: link, mouseCursor: SystemMouseCursors.click, recognizer: _recognizers[i++]),
      ]),
      style: widget.style,
    );
  }
}
