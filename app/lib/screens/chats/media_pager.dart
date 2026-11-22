// Photos and videos full screen, swiping between them (an album, or a chat's media gallery).
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../chat/db/chat_db.dart';
import '../../chat/plaintext.dart';
import 'photo_view.dart';
import 'video_view.dart';

/// Opens [items] (photo and video messages) full screen at [index].
Future<void> showMediaPager(BuildContext context, List<MessageRow> items, int index) => Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        pageBuilder: (_, _, _) => MediaPager(items: items, initial: index),
        transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
      ),
    );

class MediaPager extends StatefulWidget {
  const MediaPager({super.key, required this.items, required this.initial});

  final List<MessageRow> items;
  final int initial;

  @override
  State<MediaPager> createState() => _MediaPagerState();
}

class _MediaPagerState extends State<MediaPager> {
  late final _pages = PageController(initialPage: widget.initial);

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    if (items.length == 1) return _page(items.single);
    return PageView.builder(
      key: const Key('media-pager'),
      controller: _pages,
      itemCount: items.length,
      itemBuilder: (context, i) => _page(items[i]),
    );
  }

  Widget _page(MessageRow m) {
    final body = _decode(m);
    return switch (body) {
      PhotoBody() => PhotoViewer(key: ValueKey(m.id), body: body),
      VideoBody() => VideoViewer(key: ValueKey(m.id), body: body, messageId: m.id),
      _ => const ColoredBox(color: Colors.black),
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
