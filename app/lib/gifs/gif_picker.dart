// The GIF picker: KLIPY's trending GIFs, or search results, in a grid. KLIPY asks for "Search KLIPY"
// as the search placeholder and for results in the order it returns them.
import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../chat/plaintext.dart';
import '../theme/tokens.dart';
import 'klipy.dart';

/// The picker's search field and results; the emoji picker's GIFs tab. Calls [onPicked] with the GIF
/// tapped. [autofocus] puts the cursor in the search field (desktop and web, where no keyboard pops up).
class GifPickerPanel extends StatefulWidget {
  const GifPickerPanel({super.key, required this.client, required this.onPicked, this.autofocus = true});

  final KlipyClient client;
  final ValueChanged<GifResult> onPicked;
  final bool autofocus;

  @override
  State<GifPickerPanel> createState() => _GifPickerPanelState();
}

class _GifPickerPanelState extends State<GifPickerPanel> {
  final _field = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;
  String _query = '';
  final _items = <GifResult>[];
  int _page = 0;
  bool _more = true, _loading = false, _failed = false;

  /// Bumped per new query, so a slow earlier page can't land in a newer list.
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _field.addListener(() {
      if (_field.text.trim() == _query) return;
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 300), () {
        _query = _field.text.trim();
        _restart();
      });
    });
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 400) _load();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _field.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _restart() {
    _gen++;
    setState(() {
      _items.clear();
      _page = 0;
      _more = true;
      _loading = false;
      _failed = false;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load();
  }

  Future<void> _load() async {
    if (_loading || !_more) return;
    final gen = _gen, page = _page + 1;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final r = _query.isEmpty ? await widget.client.trending(page: page) : await widget.client.search(_query, page: page);
      if (!mounted || gen != _gen) return;
      setState(() {
        _items.addAll(r.items);
        _page = page;
        _more = r.hasMore && r.items.isNotEmpty;
        _loading = false;
      });
    } on GifException {
      if (!mounted || gen != _gen) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.md, Space.md, Space.md, Space.sm),
        child: TextField(
          key: const Key('gif-search'),
          controller: _field,
          autofocus: widget.autofocus,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Search KLIPY',
            prefixIcon: Icon(Icons.search_rounded),
            isDense: true,
          ),
        ),
      ),
      Expanded(
        child: _items.isEmpty && _failed
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text("Couldn't load GIFs.", style: theme.textTheme.bodyMedium),
                  const SizedBox(height: Space.sm),
                  TextButton(onPressed: _restart, child: const Text('Try again')),
                ]),
              )
            : _items.isEmpty && !_loading
                ? Center(child: Text(_query.isEmpty ? 'No GIFs right now.' : 'No GIFs for "$_query".'))
                : LayoutBuilder(builder: (context, c) {
                    final columns = (c.maxWidth / 130).floor().clamp(2, 5);
                    return GridView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.xs),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: Space.xs,
                        crossAxisSpacing: Space.xs,
                      ),
                      itemCount: _items.length + (_loading ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (i >= _items.length) return const Center(child: CircularProgressIndicator());
                        final g = _items[i];
                        return Semantics(
                          button: true,
                          label: g.body.title.isEmpty ? 'GIF' : g.body.title,
                          excludeSemantics: true,
                          child: Material(
                            color: s.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(Radii.sm),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              key: Key('gif-${g.slug}'),
                              onTap: () => widget.onPicked(g),
                              child: Image.network(
                                g.previewUrl,
                                fit: BoxFit.cover,
                                gaplessPlayback: true,
                                errorBuilder: (_, _, _) => Icon(Icons.gif_box_outlined, color: s.onSurfaceVariant),
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  }),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.sm),
        child: Text('Powered by KLIPY', style: theme.textTheme.labelSmall?.copyWith(color: s.onSurfaceVariant)),
      ),
    ]);
  }
}

/// A GIF in a message, loaded from KLIPY.
class GifView extends StatelessWidget {
  const GifView({super.key, required this.body, this.maxWidth = 260});

  final GifBody body;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final w = body.width.toDouble(), h = body.height.toDouble();
    final width = w.clamp(80.0, maxWidth);
    final height = (width * h / w).clamp(60.0, 360.0);
    return Semantics(
      image: true,
      label: body.title.isEmpty ? 'GIF' : 'GIF: ${body.title}',
      excludeSemantics: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.md),
        child: Container(
          width: width,
          height: height,
          color: s.surfaceContainerHighest,
          child: Image.network(
            body.url,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => Padding(
              padding: const EdgeInsets.all(Space.sm),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.gif_box_outlined, color: s.onSurfaceVariant),
                  const SizedBox(width: Space.xs),
                  Text('GIF unavailable', style: TextStyle(color: s.onSurfaceVariant)),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
