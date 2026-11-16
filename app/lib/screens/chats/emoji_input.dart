// The composer's emoji picker (emoji_picker_flutter, themed to match) and `:shortcode:` suggestions.
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart' as ep;
import 'package:flutter/foundation.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart' as legacy show Material, MaterialType;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/emoji/shortcodes.dart';
import '../../theme/tokens.dart';

/// Desktop and web show the picker as a popover; phones and tablets show it in place of the keyboard.
bool get emojiPopover =>
    kIsWeb || {TargetPlatform.linux, TargetPlatform.macOS, TargetPlatform.windows}.contains(defaultTargetPlatform);

/// The picker: recently used, categories and search. Calls [onSelected] with each emoji picked, and
/// [onBackspace] from its backspace key (shown only when given: phones, where it replaces the keyboard).
class EmojiPanel extends StatefulWidget {
  const EmojiPanel({super.key, required this.onSelected, this.onBackspace, required this.height});

  final ValueChanged<String> onSelected;
  final VoidCallback? onBackspace;
  final double height;

  @override
  State<EmojiPanel> createState() => _EmojiPanelState();
}

class _EmojiPanelState extends State<EmojiPanel> {
  /// Null until the recents are read: with none yet, the picker opens on smileys instead of an empty tab.
  bool? _hasRecents;

  @override
  void initState() {
    super.initState();
    ep.EmojiPickerUtils().getRecentEmojis().then(
          (r) => mounted ? setState(() => _hasRecents = r.isNotEmpty) : null,
          onError: (Object _) => mounted ? setState(() => _hasRecents = false) : null,
        );
  }

  @override
  Widget build(BuildContext context) {
    final hasRecents = _hasRecents;
    if (hasRecents == null) return SizedBox(height: widget.height);
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final bg = s.surfaceContainerLow;
    return LayoutBuilder(builder: (context, c) {
      final columns = (c.maxWidth / 44).floor().clamp(6, 12);
      final config = ep.Config(
        height: widget.height,
        checkPlatformCompatibility: true,
        locale: const Locale('en'),
        emojiViewConfig: ep.EmojiViewConfig(
          columns: columns,
          emojiSizeMax: 28 * (defaultTargetPlatform == TargetPlatform.iOS ? 1.2 : 1.0),
          backgroundColor: bg,
          gridPadding: const EdgeInsets.symmetric(horizontal: Space.xs),
          recentsLimit: 32,
          noRecents: const _NoRecents(),
        ),
        categoryViewConfig: ep.CategoryViewConfig(
          initCategory: hasRecents ? ep.Category.RECENT : ep.Category.SMILEYS,
          backgroundColor: bg,
          indicatorColor: s.tertiary,
          iconColor: s.onSurfaceVariant,
          iconColorSelected: s.tertiary,
          backspaceColor: s.onSurfaceVariant,
          dividerColor: s.outlineVariant,
        ),
        bottomActionBarConfig: ep.BottomActionBarConfig(
          showBackspaceButton: widget.onBackspace != null,
          backgroundColor: bg,
          buttonColor: bg,
          buttonIconColor: s.onSurfaceVariant,
        ),
        searchViewConfig: ep.SearchViewConfig(
          backgroundColor: bg,
          buttonIconColor: s.onSurfaceVariant,
          hintText: 'Search emoji',
          inputTextStyle: theme.textTheme.bodyLarge?.copyWith(color: s.onSurface),
          hintTextStyle: theme.textTheme.bodyLarge?.copyWith(color: s.onSurfaceVariant),
        ),
        skinToneConfig: ep.SkinToneConfig(dialogBackgroundColor: s.surfaceContainerHighest, indicatorColor: s.outline),
      );
      // emoji_picker_flutter is built on package:flutter/material: the bridge hands it our theme and
      // localizations, and its search field needs a Material of that library above it. Both go once the
      // package moves to material_ui.
      // ignore: deprecated_member_use
      return MaterialUiCompatibilityBridge(
        child: legacy.Material(
          type: legacy.MaterialType.transparency,
          child: ep.EmojiPicker(
            config: config,
            onEmojiSelected: (_, emoji) => widget.onSelected(emoji.emoji),
            onBackspacePressed: widget.onBackspace,
          ),
        ),
      );
    });
  }
}

class _NoRecents extends StatelessWidget {
  const _NoRecents();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      'Emoji you use show up here',
      textAlign: TextAlign.center,
      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    );
  }
}

/// Desktop and web: the emoji popover's state, shared by [EmojiPopover] and its [EmojiPopoverButton].
class EmojiPopoverHandle extends ChangeNotifier {
  final controller = OverlayPortalController();
  final link = LayerLink();

  /// Taps on the button and inside the popover are not "outside".
  final tapGroup = Object();

  bool get isShowing => controller.isShowing;

  void show() {
    controller.show();
    notifyListeners();
  }

  void hide() {
    if (!controller.isShowing) return;
    controller.hide();
    notifyListeners();
  }
}

/// Shows the picker above [EmojiPopoverButton] while [handle] is showing (desktop and web). It wraps the
/// composer: an OverlayPortal inside the field's decoration upsets the field's semantics.
class EmojiPopover extends StatelessWidget {
  const EmojiPopover({
    super.key,
    required this.handle,
    required this.onSelected,
    required this.onClosed,
    required this.child,
  });

  final EmojiPopoverHandle handle;
  final ValueChanged<String> onSelected;

  /// After the popover closes itself (a pick, Esc or a click outside).
  final VoidCallback onClosed;
  final Widget child;

  void _close() {
    if (!handle.isShowing) return;
    handle.hide();
    onClosed();
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
        controller: handle.controller,
        overlayChildBuilder: (context) {
          final s = Theme.of(context).colorScheme;
          final screen = MediaQuery.sizeOf(context);
          final width = (screen.width - 2 * Space.sm).clamp(0.0, 360.0);
          final height = (screen.height * 0.6).clamp(0.0, 400.0);
          return CompositedTransformFollower(
            link: handle.link,
            showWhenUnlinked: false,
            targetAnchor: Alignment.topRight,
            followerAnchor: Alignment.bottomRight,
            offset: const Offset(Space.xs, -Space.sm),
            child: Align(
              alignment: Alignment.bottomRight,
              child: TapRegion(
                groupId: handle.tapGroup,
                onTapOutside: (_) => _close(),
                child: CallbackShortcuts(
                  bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
                  child: FocusScope(
                    child: Material(
                      key: const Key('emoji-popover'),
                      color: s.surfaceContainerLow,
                      elevation: 3,
                      shadowColor: s.shadow.withValues(alpha: 0.25),
                      clipBehavior: Clip.antiAlias,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(Radii.md),
                        side: BorderSide(color: s.outlineVariant),
                      ),
                      child: SizedBox(
                        width: width,
                        child: EmojiPanel(
                          height: height,
                          onSelected: (e) {
                            onSelected(e);
                            _close();
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
        child: child,
      );
}

/// The button that opens and closes the emoji popover; the popover is anchored to it.
class EmojiPopoverButton extends StatelessWidget {
  const EmojiPopoverButton({super.key, required this.handle});

  final EmojiPopoverHandle handle;

  @override
  Widget build(BuildContext context) => CompositedTransformTarget(
        link: handle.link,
        child: TapRegion(
          groupId: handle.tapGroup,
          child: ListenableBuilder(
            listenable: handle,
            builder: (context, _) => IconButton(
              tooltip: 'Emoji',
              isSelected: handle.isShowing,
              icon: const Icon(Icons.emoji_emotions_outlined),
              selectedIcon: const Icon(Icons.emoji_emotions),
              onPressed: () => handle.isShowing ? handle.hide() : handle.show(),
            ),
          ),
        ),
      );
}

/// The `:shortcode:` matches shown above the composer, [selected] highlighted.
class ShortcodeSuggestions extends StatelessWidget {
  const ShortcodeSuggestions({super.key, required this.matches, required this.selected, required this.onPick});

  final List<ShortcodeMatch> matches;
  final int selected;
  final ValueChanged<ShortcodeMatch> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    return Material(
      key: const Key('shortcode-suggestions'),
      color: s.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: BorderSide(color: s.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.xs),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final (i, m) in matches.indexed)
            Semantics(
              selected: i == selected,
              child: InkWell(
                key: Key('shortcode-${m.name}'),
                onTap: () => onPick(m),
                child: Container(
                  color: i == selected ? s.secondaryContainer : null,
                  padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 6),
                  child: Row(children: [
                    SizedBox(width: 32, child: Text(m.emoji, style: const TextStyle(fontSize: 22))),
                    const SizedBox(width: Space.sm),
                    Expanded(
                      child: Text(
                        ':${m.name}:',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: i == selected ? s.onSecondaryContainer : s.onSurface,
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
