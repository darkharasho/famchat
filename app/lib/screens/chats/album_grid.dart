// Photos and videos sent together, as one grid in one bubble (docs/protocol.md "albums").
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../chat/db/chat_db.dart';
import '../../chat/plaintext.dart';
import '../../theme/tokens.dart';
import 'photo_view.dart';
import 'video_view.dart';

/// Width of an album, like the widest single photo.
const albumWidth = 260.0;
const _gap = 2.0;

/// [items] oldest first: 2 side by side, 3 as one wide over two, 4 or more as 2×2 with "+N" on the
/// fourth. Tapping a tile opens [onOpen] at it.
class AlbumGrid extends StatelessWidget {
  const AlbumGrid({super.key, required this.items, required this.onOpen});

  final List<MessageRow> items;
  final void Function(int index) onOpen;

  @override
  Widget build(BuildContext context) {
    const half = (albumWidth - _gap) / 2;
    Widget tile(int i, Size size) => AlbumTile(row: items[i], size: size, onOpen: () => onOpen(i));
    final n = items.length;
    final Widget grid;
    if (n == 2) {
      grid = Row(children: [tile(0, const Size(half, 170)), const SizedBox(width: _gap), tile(1, const Size(half, 170))]);
    } else if (n == 3) {
      grid = Column(children: [
        tile(0, const Size(albumWidth, 160)),
        const SizedBox(height: _gap),
        Row(children: [tile(1, const Size(half, 110)), const SizedBox(width: _gap), tile(2, const Size(half, 110))]),
      ]);
    } else {
      const sq = Size(half, half);
      grid = Column(children: [
        Row(children: [tile(0, sq), const SizedBox(width: _gap), tile(1, sq)]),
        const SizedBox(height: _gap),
        Row(children: [
          tile(2, sq),
          const SizedBox(width: _gap),
          Stack(children: [
            tile(3, sq),
            if (n > 4)
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(
                    color: Colors.black45,
                    child: Center(
                      child: Text(
                        '+${n - 4}',
                        key: const Key('album-more'),
                        style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
              ),
          ]),
        ]),
      ]);
    }
    return ClipRRect(
      key: const Key('album'),
      borderRadius: BorderRadius.circular(Radii.lg - 4),
      child: SizedBox(width: albumWidth, child: grid),
    );
  }
}

/// One photo or video, cropped to [size] (an album tile, or a gallery square).
class AlbumTile extends StatelessWidget {
  const AlbumTile({super.key, required this.row, required this.size, required this.onOpen});

  final MessageRow row;
  final Size size;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final body = row.body == null ? null : _decode(row.body!);
    return switch (body) {
      PhotoBody() => PhotoThumb(body: body, messageId: row.id, onOpen: onOpen, size: size, radius: 0),
      VideoBody() => VideoThumb(body: body, messageId: row.id, onOpen: onOpen, size: size, radius: 0),
      _ => SizedBox.fromSize(size: size, child: ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHigh)),
    };
  }

  static Plaintext? _decode(String body) {
    try {
      return Plaintext.decode(utf8.encode(body));
    } on FormatException {
      return null;
    }
  }
}

/// [m]'s album id, or null.
String? albumIdOf(MessageRow m) {
  if ((m.kind != 'photo' && m.kind != 'video') || m.body == null) return null;
  try {
    final j = jsonDecode(m.body!);
    final a = j is Map ? j['album'] : null;
    return a is String ? a : null;
  } on FormatException {
    return null;
  }
}
