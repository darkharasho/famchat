// Link preview cards: in a message bubble (from the message's encrypted preview), and above the
// composer while a link is being typed (from what the server fetched).
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/plaintext.dart';
import '../../chat/wire.dart';
import '../../media/media_service.dart';
import '../../media/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/link_text.dart';

/// Under a message's text: the image, site, title and description; tapping opens the link.
class LinkPreviewCard extends ConsumerWidget {
  const LinkPreviewCard({super.key, required this.preview, required this.fg, required this.meta});

  final LinkPreview preview;
  final Color fg, meta;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final image = preview.image;
    final bytes = image == null ? null : ref.watch(mediaBytesProvider(image.ref)).value;
    final uri = Uri.tryParse(preview.url);
    return Semantics(
      link: true,
      label: '${preview.siteName ?? 'Link'}: ${preview.title}',
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: uri == null ? null : () => openLink(uri),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 320),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: fg.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border(left: BorderSide(color: fg.withValues(alpha: 0.5), width: 3)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            if (image != null)
              AspectRatio(
                aspectRatio: (image.width / image.height).clamp(1.0, 2.0),
                child: bytes == null
                    ? ColoredBox(color: fg.withValues(alpha: 0.06))
                    : Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, _, _) => const SizedBox()),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                if (preview.siteName != null)
                  Text(preview.siteName!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(color: meta, fontWeight: FontWeight.w600)),
                Text(preview.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(color: fg, fontWeight: FontWeight.w700)),
                if (preview.description != null)
                  Text(preview.description!,
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: meta)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Above the composer: the preview the next send will carry, with a button to leave it off.
class ComposerPreview extends StatelessWidget {
  const ComposerPreview({super.key, required this.preview, required this.onRemove});

  final FetchedPreview preview;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final Uint8List? image = preview.image;
    return Container(
      key: const Key('composer-preview'),
      padding: const EdgeInsets.fromLTRB(Space.sm, Space.xs, Space.xs, Space.xs),
      decoration: BoxDecoration(
        color: s.surfaceContainer,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border(left: BorderSide(color: s.tertiary, width: 3)),
      ),
      child: Row(children: [
        if (image != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.sm),
            child: Image.memory(image,
                width: 56, height: 42, fit: BoxFit.cover, cacheWidth: 112, errorBuilder: (_, _, _) => const SizedBox(width: 56)),
          ),
        const SizedBox(width: Space.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            if (preview.siteName != null)
              Text(preview.siteName!,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelSmall?.copyWith(color: s.tertiary)),
            Text(preview.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelLarge),
          ]),
        ),
        IconButton(tooltip: 'Remove preview', icon: const Icon(Icons.close_rounded), onPressed: onRemove),
      ]),
    );
  }
}
