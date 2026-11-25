// Photos and videos full screen, swiping between them (an album, or a chat's media gallery).
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/db/chat_db.dart';
import '../../chat/plaintext.dart';
import 'photo_view.dart';
import 'video_view.dart';

/// Opens [items] (photo and video messages) full screen at [index].
Future<void> showMediaPager(BuildContext context, List<MessageRow> items, int index) => Navigator.of(context).push(mediaViewerRoute((_) => MediaPager(items: items, initial: index)));

class MediaPager extends StatefulWidget {
  const MediaPager({super.key, required this.items, required this.initial});

  final List<MessageRow> items;
  final int initial;

  @override
  State<MediaPager> createState() => _MediaPagerState();
}

class _MediaPagerState extends State<MediaPager> {
  late final _pages = PageController(initialPage: widget.initial);
  late var _index = widget.initial;

  @override
  void initState() {
    super.initState();
    // Each page keeps keyboard focus for its own keys (Escape, zoom), so the arrows are caught here.
    HardwareKeyboard.instance.addHandler(_key);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    _pages.dispose();
    super.dispose();
  }

  bool _key(KeyEvent e) {
    if (e is KeyUpEvent || widget.items.length < 2 || !(ModalRoute.of(context)?.isCurrent ?? false)) return false;
    if (e.logicalKey == LogicalKeyboardKey.arrowLeft) return _go(-1);
    if (e.logicalKey == LogicalKeyboardKey.arrowRight) return _go(1);
    return false;
  }

  /// Steps to the previous (-1) or next (1) item, if there is one.
  bool _go(int dir) {
    final to = _index + dir;
    if (to < 0 || to >= widget.items.length) return false;
    setState(() => _index = to);
    _pages.animateToPage(to, duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    if (items.length == 1) return _page(items.single);
    Widget arrow(int dir) => Center(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: IconButton.filled(
              key: Key(dir < 0 ? 'media-previous' : 'media-next'),
              tooltip: dir < 0 ? 'Previous' : 'Next',
              style: IconButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white),
              icon: Icon(dir < 0 ? Icons.chevron_left_rounded : Icons.chevron_right_rounded),
              onPressed: () => _go(dir),
            ),
          ),
        );
    return Stack(fit: StackFit.expand, children: [
      PageView.builder(
        key: const Key('media-pager'),
        controller: _pages,
        itemCount: items.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, i) => _page(items[i]),
      ),
      if (mouseFirst && _index > 0) Positioned(left: 0, top: 0, bottom: 0, child: SafeArea(child: arrow(-1))),
      if (mouseFirst && _index < items.length - 1)
        Positioned(right: 0, top: 0, bottom: 0, child: SafeArea(child: arrow(1))),
    ]);
  }

  Widget _page(MessageRow m) {
    final body = _decode(m);
    return switch (body) {
      PhotoBody() => PhotoViewer(key: ValueKey(m.id), body: body),
      VideoBody() => VideoViewer(key: ValueKey(m.id), body: body, messageId: m.id),
      _ => const SizedBox.expand(),
    };
  }

  static Plaintext? _decode(MessageRow m) {
    if (m.body == null) return null;
    try {
      return Plaintext.decode(utf8.encode(m.body!));
    } on FormatException {
      return null;
    }
  }
}
