import 'dart:async';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/db/chat_db.dart';
import '../../chat/emoji/emoticons.dart';
import '../../chat/emoji/shortcodes.dart';
import '../../chat/forward.dart';
import '../../chat/mentions.dart';
import '../../chat/wire.dart' show FetchedPreview;
import '../../widgets/link_text.dart' show splitLinks;
import '../../chat/message_changes.dart';
import '../../chat/providers.dart';
import '../../chat/spelling/providers.dart';
import '../../chat/spelling/speller.dart';
import '../../chat/reactions.dart';
import '../../games/game_state.dart' show GameState, activeGames;
import '../../games/providers.dart';
import '../../games/widgets/game_bar.dart';
import '../../games/widgets/game_card.dart';
import '../../games/widgets/game_event_line.dart';
import '../../games/labels.dart' show gameEventsOf;
import '../../games/widgets/start_game_sheet.dart';
import '../../gifs/klipy.dart' show GifResult;
import '../../gifs/providers.dart';
import '../../media/clipboard_media.dart';
import '../../media/media_service.dart';
import '../../media/photo_picker.dart';
import '../../media/send_media.dart';
import '../../media/providers.dart';
import '../../voice/providers.dart';
import '../../voice/recording.dart';
import '../../voice/waveform.dart';
import '../../theme/tokens.dart';
import '../../widgets/common.dart';
import '../../widgets/person_avatar.dart';
import '../../widgets/typing_dots.dart';
import 'chat_list.dart' show messageSnippet;
import 'chats_shell.dart' show shortcutModifier;
import 'emoji_input.dart';
import 'link_preview_card.dart';
import 'forward_picker.dart';
import 'mention_suggestions.dart';
import 'message_bubble.dart';
import 'record_bar.dart';
import 'timeline.dart';

/// One chat: header, messages, typing line and the composer.
class ConversationView extends ConsumerStatefulWidget {
  const ConversationView({super.key, required this.chatId, this.showBack = true, this.jumpTo});

  final String chatId;
  final bool showBack;

  /// A message to scroll to once the messages are loaded (from search).
  final String? jumpTo;

  @override
  ConsumerState<ConversationView> createState() => _ConversationViewState();
}

class _ConversationViewState extends ConsumerState<ConversationView> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  late final VoiceRecording _recording;
  late final ProviderContainer _container;

  /// Where a recording goes, fixed when it starts: the clip still sends if the user leaves the chat
  /// while the recorder is finishing (when `ref` can no longer be used).
  MediaService? _voiceTarget;
  bool _empty = true;
  RecordingStatus _recStatus = RecordingStatus.idle;

  /// Phones: the emoji picker is showing in place of the keyboard.
  bool _pickerOpen = false;

  /// The last on-screen keyboard height, so the picker can take its place at the same size.
  double _keyboardHeight = 300;

  /// Desktop and web: the emoji popover.
  final _emojiPopover = EmojiPopoverHandle();

  /// The `:partial` being typed, its matches and the highlighted one.
  ShortcodeQuery? _query;
  List<ShortcodeMatch> _matches = const [];
  int _selected = 0;

  /// Where a query closed with Esc started: it stays closed until the user moves on.
  int? _dismissedAt;

  /// The `@name` being typed in a group, and the members it matches.
  MentionQuery? _mentionQuery;
  List<Person> _peopleMatches = const [];

  /// Which query the suggestions are for (the highlight resets when it changes).
  String? _suggestKey;

  /// Who can be @mentioned here (other members of a group: id → name); set in build.
  Map<String, String> _people = const {};

  /// A game can be started here (a direct chat that isn't read-only); set in build.
  bool _canStartGame = false;

  /// The message the next send replies to, or the one being edited (at most one of the two).
  MessageRow? _replyTo, _editing;

  /// The link being previewed, what the server found for it (null while loading or nothing), and
  /// a link whose preview was removed (it stays off while that link is in the text).
  String? _previewUrl, _dismissedPreviewUrl;
  FetchedPreview? _preview;
  Timer? _previewTimer;

  /// The fetch for [_previewUrl] while it runs, so a send can wait for it.
  Future<void>? _previewLoad;

  /// The fetch for [_previewUrl] (kept when done): a text sent before it finished gets the preview
  /// attached afterwards.
  Future<FetchedPreview?>? _previewFetch;

  /// A send is waiting for its link's preview (a second tap must not send twice).
  bool _waitingForPreview = false;

  /// The first web link in [text], if any.
  static String? _firstLink(String text) {
    for (final p in splitLinks(text)) {
      if (p.uri != null) return p.uri.toString();
    }
    return null;
  }

  void _schedulePreview() {
    _previewTimer?.cancel();
    _previewTimer = Timer(const Duration(milliseconds: 500), _checkPreview);
  }

  Future<void> _checkPreview() async {
    final url = _editing == null ? _firstLink(_text.text) : null;
    if (url == null || url == _dismissedPreviewUrl) {
      if (_previewUrl != null && mounted) setState(() => _previewUrl = _preview = null);
      return;
    }
    if (url == _previewUrl) return;
    setState(() {
      _previewUrl = url;
      _preview = null;
    });
    final fetch = _previewFetch = ref.read(chatApiProvider).preview(url);
    final load = _previewLoad = fetch.then((_) {}, onError: (Object _) {});
    FetchedPreview? found;
    try {
      found = await fetch;
    } catch (_) {
      found = null; // offline or the site said no: the link just sends plain
    } finally {
      if (identical(_previewLoad, load)) _previewLoad = null;
    }
    if (mounted && _previewUrl == url) setState(() => _preview = found);
  }

  /// Sending right after pasting a link (usual on phones, where the composer card has no time to
  /// show): wait briefly for its preview, so the message still carries one.
  Future<void> _awaitPreviewFor(String text) async {
    final url = _firstLink(text);
    if (url == null || url == _dismissedPreviewUrl || (url == _previewUrl && _previewLoad == null)) return;
    _previewTimer?.cancel();
    final load = url == _previewUrl ? _previewLoad : _checkPreview();
    if (load == null) return;
    await load.timeout(const Duration(seconds: 3), onTimeout: () {});
  }

  void _removePreview() => setState(() {
        _dismissedPreviewUrl = _previewUrl;
        _previewUrl = _preview = null;
      });

  /// The draft set aside while editing a message, put back when the edit ends.
  String _stashedDraft = '';

  /// The draft as last written to the database, and the pending write.
  String _savedDraft = '';
  Timer? _draftTimer;

  /// A message just jumped to, tinted for a moment.
  String? _highlight;
  Timer? _unhighlight;
  final _scroll = ScrollController();
  final _bubbleKeys = <String, GlobalKey>{};

  GlobalKey _keyFor(String id) => _bubbleKeys.putIfAbsent(id, GlobalKey.new);

  /// The [ConversationView.jumpTo] already scrolled to.
  String? _jumped;

  void _maybeJump(bool loaded) {
    final target = widget.jumpTo;
    if (target == null || !loaded || _jumped == target) return;
    _jumped = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_jumpTo(target));
    });
  }

  @override
  void initState() {
    super.initState();
    _recording = VoiceRecording(ref.read(voiceRecorderFactoryProvider), onAutoStop: _sendVoice);
    _container = ProviderScope.containerOf(context, listen: false);
    _recording.addListener(() {
      if (_recording.status != _recStatus && mounted) setState(() => _recStatus = _recording.status);
    });
    // Desktop (and web on a desktop OS): type straight away. Phones and tablets wait for a tap, since
    // focus would raise the on-screen keyboard.
    if ({TargetPlatform.linux, TargetPlatform.macOS, TargetPlatform.windows}.contains(defaultTargetPlatform)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
    HardwareKeyboard.instance.addHandler(_typeToFocus);
    _draftKey = '${ref.read(myUserIdProvider)}|${widget.chatId}';
    _text.addListener(() {
      final empty = _text.text.trim().isEmpty;
      if (empty != _empty && mounted) setState(() => _empty = empty);
      _updateSuggestions();
      _scheduleDraftSave();
      _schedulePreview();
    });
    unawaited(_loadDraft());
    _webPaste = listenForPastedFiles(() => mounted && _focus.hasFocus, (files) async {
      final sorted = await pickedFromFiles(files);
      await _confirmPaste(sorted.media);
    });
  }

  /// Web: photos and videos pasted into the composer.
  StreamSubscription<Object?>? _webPaste;

  /// The latest draft of each chat this run (keyed by user and chat), ahead of the database write:
  /// a view replaced at once (the window crossing the wide layout) starts from it.
  static final _latestDrafts = <String, String>{};

  late final String _draftKey;

  Future<void> _loadDraft() async {
    if (_latestDrafts[_draftKey] case final latest?) {
      if (latest.isNotEmpty && _text.text.isEmpty && _editing == null) {
        _savedDraft = latest;
        _text.value = TextEditingValue(text: latest, selection: TextSelection.collapsed(offset: latest.length));
      }
      return;
    }
    final draft = await ref.read(chatDbProvider).draftOf(widget.chatId);
    // Typing (or an edit) that began meanwhile wins.
    if (draft == null || !mounted || _text.text.isNotEmpty || _editing != null) return;
    _savedDraft = draft;
    _text.value = TextEditingValue(text: draft, selection: TextSelection.collapsed(offset: draft.length));
  }

  /// What this chat's draft is now: the composer, or what it held before an edit began.
  String get _draft => _editing != null ? _stashedDraft : _text.text;

  void _scheduleDraftSave() {
    _latestDrafts[_draftKey] = _draft;
    if (_draft == _savedDraft) return;
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 400), _saveDraftNow);
  }

  void _saveDraftNow() {
    _draftTimer?.cancel();
    final draft = _draft;
    if (draft == _savedDraft) return;
    _savedDraft = draft;
    // Through the container: this also runs from dispose, where `ref` can't be used.
    unawaited(_container.read(chatDbProvider).setDraft(widget.chatId, draft));
  }

  void _updateSuggestions() {
    final mq = _people.isEmpty ? null : mentionQueryAt(_text.value);
    final q = mq == null ? shortcodeQueryAt(_text.value) : null;
    final start = mq?.start ?? q?.start;
    if (start != _dismissedAt) _dismissedAt = null;
    final dismissed = start != null && start == _dismissedAt;
    final people = mq == null || dismissed ? const <Person>[] : matchingPeople(mq.query, _people).take(6).toList();
    final matches = q == null || dismissed ? const <ShortcodeMatch>[] : searchShortcodes(q.query, limit: 6);
    final key = mq != null ? '@${mq.start}:${mq.query}' : (q != null ? ':${q.start}:${q.query}' : null);
    final same = key == _suggestKey;
    if (!mounted) return;
    if (same && _matches.length == matches.length && _peopleMatches.length == people.length) {
      _query = q;
      _mentionQuery = mq;
      return;
    }
    setState(() {
      _query = q;
      _mentionQuery = mq;
      _matches = matches;
      _peopleMatches = people;
      _suggestKey = key;
      if (!same) _selected = 0;
    });
  }

  bool get _mentioning => _peopleMatches.isNotEmpty && _mentionQuery != null;

  bool get _suggesting => (_matches.isNotEmpty && _query != null) || _mentioning;

  void _pickSuggestion([ShortcodeMatch? m]) {
    if (_mentioning) return _pickPerson(_peopleMatches[_selected]);
    final query = _query;
    if (query == null || _matches.isEmpty) return;
    _text.value = replaceShortcodeQuery(_text.value, query, (m ?? _matches[_selected]).emoji);
    if (!_pickerOpen) _focus.requestFocus();
  }

  void _pickPerson(Person p) {
    final query = _mentionQuery;
    if (query == null) return;
    _text.value = insertMention(_text.value, query, p.name);
    if (!_pickerOpen) _focus.requestFocus();
  }

  void _moveSelection(int by) =>
      setState(() => _selected = (_selected + by) % (_mentioning ? _peopleMatches.length : _matches.length));

  void _dismissSuggestions() => setState(() {
        _dismissedAt = _mentionQuery?.start ?? _query?.start;
        _matches = const [];
        _peopleMatches = const [];
      });

  void _insertEmoji(String emoji) => _text.value = insertEmoji(_text.value, emoji);

  /// Phones: swap the keyboard for the picker, or back.
  void _togglePicker() {
    if (_pickerOpen) {
      setState(() => _pickerOpen = false);
      _focus.requestFocus();
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
    } else {
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
      setState(() => _pickerOpen = true);
    }
  }

  /// Typing while nothing takes text (say, after clicking a message) goes to the composer, key
  /// included. Shortcuts (Ctrl/Cmd) and other text fields are left alone, as is this chat when a
  /// dialog or another screen is on top of it.
  bool _typeToFocus(KeyEvent event) {
    if (event is! KeyDownEvent || !mounted || _focus.hasFocus || _focus.context == null) return false;
    final ch = event.character;
    if (ch == null || ch.isEmpty || ch.runes.any((r) => r < 0x20 || r == 0x7f)) return false;
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isMetaPressed) return false;
    if (ModalRoute.of(context)?.isCurrent == false) return false;
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null && (focused.widget is EditableText || focused.findAncestorWidgetOfExactType<EditableText>() != null)) {
      return false;
    }
    // A space would otherwise press the focused button; a leading space in a message is no loss.
    if (ch == ' ' && _text.text.isEmpty) return false;
    _focus.requestFocus();
    final v = _text.value;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    _text.value = TextEditingValue(
      text: v.text.replaceRange(sel.start, sel.end, ch),
      selection: TextSelection.collapsed(offset: sel.start + ch.length),
    );
    return true;
  }

  /// Desktop and web spell checking: the word list, and what else counts as a word (family
  /// members' names, words added to this user's dictionary). A new service when either changes, so
  /// the composer checks again.
  Speller? _speller;
  Set<String> _knownWords = const {};
  WordListSpellCheckService? _spellService;

  /// Where the latest right-click in the composer landed (global), for [_contextMenu].
  Offset? _secondaryClickAt;

  SpellCheckConfiguration? _spellCheck() {
    if (!usesWordListSpelling) {
      return WidgetsBinding.instance.platformDispatcher.nativeSpellCheckServiceDefined ? const SpellCheckConfiguration() : null;
    }
    final speller = ref.watch(spellerProvider).value;
    if (speller == null) return null;
    final known = <String>{
      for (final u in (ref.watch(usersProvider).value ?? const <String, UserRow>{}).values)
        for (final part in u.name.toLowerCase().split(RegExp(r'\s+')))
          if (part.isNotEmpty) part,
      ...?ref.watch(userWordsProvider).value,
    };
    if (!identical(speller, _speller) || !setEquals(known, _knownWords) || _spellService == null) {
      _speller = speller;
      _knownWords = known;
      _spellService = WordListSpellCheckService(speller, known.contains);
    }
    return SpellCheckConfiguration(
      spellCheckService: _spellService,
      misspelledTextStyle: TextField.materialMisspelledTextStyle,
    );
  }

  /// Right-click on a flagged word (desktop, web): its corrections and "Add to dictionary" above
  /// the usual cut/copy/paste.
  Widget _contextMenu(BuildContext context, EditableTextState state) {
    final speller = _speller;
    final value = state.currentTextEditingValue;
    // Where the right-click was: Linux and Windows leave the caret where it is.
    final clicked = _secondaryClickAt;
    _secondaryClickAt = null;
    final index = clicked != null
        ? state.renderEditable.getPositionForPoint(clicked).offset
        : value.selection.isValid
            ? value.selection.baseOffset
            : null;
    // (findSuggestionSpanAtCursorIndex throws when nothing is flagged.)
    final flagged = state.spellCheckResults?.suggestionSpans.isNotEmpty ?? false;
    final span = speller == null || !usesWordListSpelling || index == null || !flagged
        ? null
        : state.findSuggestionSpanAtCursorIndex(index);
    if (speller == null || span == null) {
      return AdaptiveTextSelectionToolbar.buttonItems(anchors: state.contextMenuAnchors, buttonItems: _menuItems(state));
    }
    final word = span.range.textInside(value.text);
    void replace(String fix) {
      state.userUpdateTextEditingValue(
        TextEditingValue(
          text: value.text.replaceRange(span.range.start, span.range.end, fix),
          selection: TextSelection.collapsed(offset: span.range.start + fix.length),
        ),
        SelectionChangedCause.toolbar,
      );
      state.hideToolbar();
    }

    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: [
        for (final fix in speller.suggest(word)) ContextMenuButtonItem(label: fix, onPressed: () => replace(fix)),
        ContextMenuButtonItem(
          label: 'Add to dictionary',
          onPressed: () {
            state.hideToolbar();
            unawaited(ref.read(userWordsProvider.notifier).add(word));
          },
        ),
        ..._menuItems(state),
      ],
    );
  }

  /// The field's usual menu items, with Paste sending a photo or video on the clipboard. Phones
  /// always offer Paste: their menus only show it for text, and a copied photo has none.
  List<ContextMenuButtonItem> _menuItems(EditableTextState state) {
    final items = state.contextMenuButtonItems;
    final paste = items.indexWhere((i) => i.type == ContextMenuButtonType.paste);
    if (paste == -1) {
      if (!_touch || state.widget.readOnly) return items;
      return [
        ...items,
        ContextMenuButtonItem(
          type: ContextMenuButtonType.paste,
          onPressed: () {
            state.hideToolbar();
            unawaited(_pasteMedia(() => _snack('Nothing to paste.')));
          },
        ),
      ];
    }
    final usual = items[paste].onPressed;
    return [
      for (final (i, item) in items.indexed)
        if (i != paste)
          item
        else
          item.copyWith(onPressed: () {
            state.hideToolbar();
            unawaited(_pasteMedia(usual));
          }),
    ];
  }

  /// Offers to send the photos and videos on the clipboard; with none, runs [otherwise] (the usual
  /// text paste).
  Future<void> _pasteMedia(VoidCallback? otherwise) async {
    final media = await ref.read(clipboardMediaProvider)();
    if (!mounted) return;
    if (media.isEmpty) {
      otherwise?.call();
      return;
    }
    await _confirmPaste(media);
  }

  /// Asks before sending pasted [media] (a stray paste shouldn't reach the family), showing the
  /// first photo.
  Future<void> _confirmPaste(List<PickedMedia> media) async {
    if (media.isEmpty || !mounted) return;
    final photo = media.whereType<PickedPhoto>().firstOrNull;
    final videos = media.whereType<PickedVideo>().length;
    final title = media.length == 1
        ? (videos == 1 ? 'Send this video?' : 'Send this photo?')
        : videos == 0
            ? 'Send ${media.length} photos?'
            : videos == media.length
                ? 'Send ${media.length} videos?'
                : 'Send ${media.length} photos and videos?';
    final send = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('paste-confirm'),
        title: Text(title),
        content: photo == null
            ? null
            : ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360, maxHeight: 360),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.md),
                  child: Image.memory(
                    photo.bytes,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Icon(Icons.image_outlined, size: 64),
                  ),
                ),
              ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(autofocus: true, onPressed: () => Navigator.pop(context, true), child: const Text('Send')),
        ],
      ),
    );
    if (send == true && mounted) {
      await sendPicked(media);
      _focus.requestFocus();
    }
  }

  /// Phones and tablets, where taps elsewhere should put the keyboard away.
  bool get _touch => {TargetPlatform.android, TargetPlatform.iOS}.contains(defaultTargetPlatform);

  void _dismissInput() {
    _focus.unfocus();
    _closePicker();
  }

  void _closePicker() {
    if (_pickerOpen) setState(() => _pickerOpen = false);
  }

  @override
  void dispose() {
    unawaited(_webPaste?.cancel());
    HardwareKeyboard.instance.removeHandler(_typeToFocus);
    _recording.dispose(); // discards an unsent recording (one being finished still sends)
    // No voice keeps playing without its bubble on screen (after this frame: providers cannot change
    // while the tree is building).
    final container = _container;
    unawaited(Future(() async {
      try {
        await container.read(voicePlaybackProvider.notifier).stop();
      } on StateError {
        // the whole app went away
      }
    }));
    _saveDraftNow();
    _previewTimer?.cancel();
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    _unhighlight?.cancel();
    _emojiPopover.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    _closePicker();
    if (_emojiPopover.isShowing) _emojiPopover.hide();
    unawaited(ref.read(voicePlaybackProvider.notifier).stop());
    _voiceTarget = ref.read(mediaServiceProvider);
    await _recording.start();
    switch (_recording.status) {
      case RecordingStatus.denied:
        _snack("FamChat can't use the microphone. Allow microphone access in your device settings.");
      case RecordingStatus.failed:
        _snack("Couldn't start recording.");
      default:
        break;
    }
  }

  Future<void> _finishRecording() async {
    final clip = await _recording.finish();
    if (clip == null) {
      _snack("Couldn't record that voice message.");
      return;
    }
    await _sendVoice(clip);
  }

  Future<void> _sendVoice(RecordedVoice clip) async {
    final media = _voiceTarget;
    if (media == null) {
      _snack("Couldn't send that voice message.");
      return;
    }
    try {
      await media.sendVoice(widget.chatId, clip);
    } on ArgumentError {
      _snack("That voice message can't be sent.");
    } catch (_) {
      _snack("Couldn't send that voice message.");
    }
  }

  void _markRead() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(chatSyncProvider)?.markRead(widget.chatId));
    });
  }

  Future<void> _send() async {
    final sync = ref.read(chatSyncProvider);
    final text = replaceTrailingEmoticon(_text.text);
    if (sync == null || text.trim().isEmpty) return;
    final editing = _editing, replyTo = _replyTo;
    if (editing != null && _changes.isDeleted(editing.id)) {
      _cancelCompose();
      _snack('That message was deleted.');
      return;
    }
    try {
      if (editing != null) {
        if (text.trim() != _currentText(editing)?.trim()) await sync.editText(widget.chatId, editing.id, text);
      } else {
        if (_waitingForPreview) return;
        _waitingForPreview = true;
        try {
          await _awaitPreviewFor(text);
        } finally {
          _waitingForPreview = false;
        }
        if (!mounted) return;
        final preview = _preview;
        final media = ref.read(mediaServiceProvider);
        final link = _firstLink(text);
        if (preview != null && media != null && link == _previewUrl) {
          await media.sendTextWithPreview(widget.chatId, text, preview,
              replyTo: replyTo?.id, mentions: mentionsIn(text, _people));
        } else {
          // Its preview may still be on the way (the wait above is short): attach it once it comes.
          final late = link != null && link == _previewUrl && link != _dismissedPreviewUrl ? _previewFetch : null;
          final id = await sync.sendText(widget.chatId, text, replyTo: replyTo?.id, mentions: mentionsIn(text, _people));
          if (late != null && media != null) unawaited(media.attachLatePreview(widget.chatId, id, late));
        }
        _previewTimer?.cancel();
        if (mounted) setState(() => _previewUrl = _preview = _dismissedPreviewUrl = null);
      }
      if (editing != null) {
        _endEdit();
      } else {
        _text.clear();
        if (mounted) setState(() => _replyTo = null);
      }
      _saveDraftNow();
    } on ArgumentError {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That message is too long.')));
      }
    }
    if (!_pickerOpen) _focus.requestFocus();
  }

  /// The latest changes over this chat's messages (set in build).
  MessageChanges _changes = messageChanges(const []);

  String? _currentText(MessageRow m) => _changes.textOf(m);

  void _startReply(MessageRow m) {
    if (_editing != null) _endEdit();
    setState(() => _replyTo = m);
    _focus.requestFocus();
  }

  void _startEdit(MessageRow m) {
    final text = _currentText(m);
    if (text == null) return;
    if (_editing == null) _stashedDraft = _text.text;
    setState(() {
      _editing = m;
      _replyTo = null;
    });
    _text.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    _focus.requestFocus();
  }

  /// Leaves edit mode and puts the set-aside draft back in the composer.
  void _endEdit() {
    final draft = _stashedDraft;
    _stashedDraft = '';
    setState(() => _editing = null);
    _text.value = TextEditingValue(text: draft, selection: TextSelection.collapsed(offset: draft.length));
  }

  void _cancelCompose() {
    if (_editing != null) _endEdit();
    setState(() => _replyTo = null);
  }

  Future<void> _delete(MessageRow m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete for everyone?'),
        content: const Text('It will show as deleted in this chat. Anyone who already saw it may remember it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (_editing?.id == m.id || _replyTo?.id == m.id) _cancelCompose();
    await ref.read(chatSyncProvider)?.deleteMessage(widget.chatId, m.id);
  }

  Future<void> _forward(MessageRow m) async {
    final to = await showForwardPicker(context, fromChatId: widget.chatId);
    if (to == null || !mounted) return;
    final sync = ref.read(chatSyncProvider);
    if (sync == null) return;
    try {
      await forwardMessage(
        message: m,
        changes: _changes,
        toChatId: to.id,
        sync: sync,
        media: ref.read(mediaServiceProvider),
      );
      _snack('Forwarded to ${to.title}');
    } on ForwardException catch (e) {
      _snack(e.reason == 'media expired' ? "That's no longer available to forward." : "That message can't be forwarded.");
    } catch (_) {
      _snack("Couldn't forward that message.");
    }
  }

  /// Scrolls until [id]'s bubble is built, centers it and tints it for a moment.
  Future<void> _jumpTo(String id) async {
    for (var i = 0; i < 60; i++) {
      final ctx = _bubbleKeys[id]?.currentContext;
      if (ctx != null && ctx.mounted) {
        await Scrollable.ensureVisible(ctx, alignment: 0.5, duration: const Duration(milliseconds: 250));
        if (!mounted) return;
        setState(() => _highlight = id);
        _unhighlight?.cancel();
        _unhighlight = Timer(const Duration(milliseconds: 1200), () {
          if (mounted) setState(() => _highlight = null);
        });
        return;
      }
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      if (pos.pixels >= pos.maxScrollExtent) break;
      // The list runs bottom-up: older messages are further along.
      _scroll.jumpTo(math.min(pos.pixels + pos.viewportDimension * 0.8, pos.maxScrollExtent));
      await WidgetsBinding.instance.endOfFrame;
    }
    _snack("That message isn't available.");
  }

  /// Sends a GIF picked in the emoji picker's GIFs tab (the picker closes itself on desktop and web).
  Future<void> _sendGif(GifResult picked) async {
    _closePicker();
    final client = ref.read(gifClientProvider).value;
    final sync = ref.read(chatSyncProvider);
    if (sync == null) return;
    await sync.enqueueMessage(widget.chatId, picked.body);
    if (client != null) unawaited(client.share(picked.slug));
  }

  /// Photos and videos being compressed and encrypted (before they appear in the list).
  int _preparing = 0;

  /// Files are being dragged over the conversation (desktop and web).
  bool _dragging = false;

  /// Photos and videos dropped on the conversation are sent.
  Widget _dropZone(Widget child) {
    final theme = Theme.of(context);
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) async {
        setState(() => _dragging = false);
        final sorted = await pickedFromFiles(details.files.whereType<DropItemFile>().toList());
        if (sorted.skipped > 0 || details.files.length > sorted.media.length + sorted.skipped) {
          _snack('Only photos and videos can be sent here.');
        }
        await sendPicked(sorted.media);
      },
      child: Stack(children: [
        child,
        if (_dragging)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                key: const Key('drop-overlay'),
                margin: const EdgeInsets.all(Space.md),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(Radii.lg),
                  border: Border.all(color: theme.colorScheme.tertiary, width: 2),
                ),
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.file_download_outlined, size: 40, color: theme.colorScheme.onTertiaryContainer),
                    const SizedBox(height: Space.sm),
                    Text('Drop photos or videos to send',
                        style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onTertiaryContainer)),
                  ]),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  Future<void> _startGame() => showStartGameSheet(context, widget.chatId);

  /// The "+" menu: the library, the camera where there is one, and Game where one can start. Phones
  /// show it as a sheet; desktop and web as a menu by the button ([anchor]'s context).
  Future<void> _attach(BuildContext anchor) async {
    final items = <(IconData, String, Object)>[
      (Icons.photo_library_outlined, 'Photos and videos', PickSource.library),
      if (cameraAvailable) ...[
        (Icons.photo_camera_outlined, 'Take a photo', PickSource.camera),
        (Icons.videocam_outlined, 'Record a video', PickSource.cameraVideo),
      ],
      if (_canStartGame) (Icons.casino_outlined, 'Game', _gameChoice),
    ];
    // A PickSource, or [_gameChoice].
    final Object? choice;
    if (emojiPopover) {
      final button = anchor.findRenderObject()! as RenderBox;
      final overlay = Overlay.of(anchor).context.findRenderObject()! as RenderBox;
      final rect = Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(button.size.bottomRight(Offset.zero), ancestor: overlay),
      );
      choice = await showMenu<Object>(
        context: anchor,
        position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
        items: [
          for (final (icon, label, value) in items)
            PopupMenuItem(
              value: value,
              child: ListTile(leading: Icon(icon), title: Text(label)),
            ),
        ],
      );
    } else {
      choice = await showModalBottomSheet<Object>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final (icon, label, value) in items)
              ListTile(
                leading: Icon(icon),
                title: Text(label),
                onTap: () => Navigator.pop(context, value),
              ),
          ]),
        ),
      );
    }
    if (choice == _gameChoice) {
      if (mounted) await _startGame();
      return;
    }
    if (choice is! PickSource || !mounted) return;
    final source = choice;
    final List<PickedMedia> picked;
    try {
      picked = await ref.read(photoPickerProvider)(source);
    } catch (e) {
      _snack("Couldn't open the picker.");
      return;
    }
    await sendPicked(picked);
  }

  /// Sends each photo and video as its own message, saying which couldn't be sent.
  Future<void> sendPicked(List<PickedMedia> picked) async {
    final media = ref.read(mediaServiceProvider);
    if (media == null || picked.isEmpty) return;
    final report = await sendMedia(
      media,
      ref.read(videoProcessorProvider),
      widget.chatId,
      picked,
      onStart: () {
        if (mounted) setState(() => _preparing++);
      },
      onEnd: () {
        if (mounted) setState(() => _preparing--);
      },
    );
    if (report.problem case final p?) _snack(p);
  }

  void _snack(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  bool get _enterSends =>
      kIsWeb || {TargetPlatform.linux, TargetPlatform.macOS, TargetPlatform.windows}.contains(defaultTargetPlatform);

  /// "+" (the attach menu), the text field, and Send (or the mic while the field is empty and recording
  /// works here).
  Widget _composer(bool canRecord) {
    final scheme = Theme.of(context).colorScheme;
    final t = FamTokens.of(context);
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      if (_editing == null)
        Builder(
          builder: (context) => IconButton(
            tooltip: 'Attach',
            icon: const Icon(Icons.add_rounded),
            style: IconButton.styleFrom(fixedSize: const Size.square(48)),
            onPressed: () => _attach(context),
          ),
        )
      else
        const SizedBox(width: Space.sm),
      Expanded(
        child: CallbackShortcuts(
          bindings: _suggesting
              ? {
                  const SingleActivator(LogicalKeyboardKey.arrowDown): () => _moveSelection(1),
                  const SingleActivator(LogicalKeyboardKey.arrowUp): () => _moveSelection(-1),
                  const SingleActivator(LogicalKeyboardKey.enter): _pickSuggestion,
                  const SingleActivator(LogicalKeyboardKey.tab): _pickSuggestion,
                  const SingleActivator(LogicalKeyboardKey.escape): _dismissSuggestions,
                }
              : {
                  if (_enterSends) const SingleActivator(LogicalKeyboardKey.enter): _send,
                  // Esc cancels a reply or edit; with a draft, it only leaves the field; a second
                  // Esc (the shell's) closes the chat.
                  const SingleActivator(LogicalKeyboardKey.escape): () => _emojiPopover.isShowing
                      ? _emojiPopover.hide()
                      : _editing != null || _replyTo != null
                          ? _cancelCompose()
                          : _text.text.isEmpty
                              ? context.go('/')
                              : _focus.unfocus(),
                },
          child: Actions(
            actions: {PasteTextIntent: _PasteMediaAction(_pasteMedia)},
            child: Listener(
            onPointerDown: (e) {
              if (e.buttons & kSecondaryMouseButton != 0) _secondaryClickAt = e.position;
            },
            child: TextField(
            key: const Key('composer'),
            controller: _text,
            focusNode: _focus,
            minLines: 1,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            keyboardType: TextInputType.multiline,
            spellCheckConfiguration: _spellCheck(),
            contextMenuBuilder: _contextMenu,
            inputFormatters: const [ShortcodeFormatter(), EmoticonFormatter()],
            // Android keyboards: images from the keyboard's clipboard, stickers and GIFs.
            contentInsertionConfiguration: ContentInsertionConfiguration(
              allowedMimeTypes: const ['image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/heic'],
              onContentInserted: (content) {
                if (content.data case final bytes? when bytes.isNotEmpty) {
                  unawaited(_confirmPaste([PickedPhoto(bytes)]));
                }
              },
            ),
            onTap: _closePicker,
            style: Theme.of(context).textTheme.bodyLarge,
            decoration: InputDecoration(
              hintText: 'Message',
              suffixIcon: emojiPopover
                  ? EmojiPopoverButton(handle: _emojiPopover)
                  : IconButton(
                      tooltip: _pickerOpen ? 'Keyboard' : 'Emoji',
                      icon: Icon(_pickerOpen ? Icons.keyboard_outlined : Icons.emoji_emotions_outlined),
                      onPressed: _togglePicker,
                    ),
              filled: true,
              fillColor: t.theirsBubble,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide(color: scheme.outlineVariant),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide(color: scheme.outlineVariant),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide(color: scheme.tertiary, width: 1.5),
              ),
            ),
            onChanged: (_) => ref.read(chatSyncProvider)?.typing(widget.chatId),
          ),
          ),
          ),
        ),
      ),
      const SizedBox(width: Space.sm),
      if (_editing != null)
        IconButton.filled(
          tooltip: 'Save edit',
          style: IconButton.styleFrom(fixedSize: const Size.square(48)),
          icon: const Icon(Icons.check_rounded),
          onPressed: _send,
        )
      else if (_empty && canRecord)
        IconButton.filled(
          tooltip: 'Record voice message',
          style: IconButton.styleFrom(fixedSize: const Size.square(48)),
          icon: const Icon(Icons.mic_rounded),
          onPressed: _startRecording,
        )
      else
        IconButton.filled(
          tooltip: 'Send',
          style: IconButton.styleFrom(fixedSize: const Size.square(48)),
          icon: const Icon(Icons.arrow_upward_rounded),
          onPressed: _send,
        ),
    ]);
  }

  /// Ids on screen when the conversation opened: those don't animate in, later ones do.
  Set<String>? _initialIds;

  /// Ids that have already played their entrance (rows are rebuilt as the list shifts or scrolls).
  final _animated = <String>{};

  @override
  Widget build(BuildContext context) {
    final chatId = widget.chatId;
    final chat = ref.watch(chatProvider(chatId)).value;
    final members = ref.watch(membersProvider(chatId)).value ?? const <MemberRow>[];
    final users = ref.watch(usersProvider).value ?? const <String, UserRow>{};
    final me = ref.watch(myUserIdProvider);
    final online = ref.watch(onlineProvider).value ?? const <String>{};
    final typing = ref.watch(typingProvider(chatId)).value ?? const <String>{};
    final loaded = ref.watch(messagesProvider(chatId));
    final messages = loaded.value ?? const <MessageRow>[];
    if (_initialIds == null && loaded.hasValue) _initialIds = {for (final m in messages) m.id};
    _maybeJump(loaded.hasValue);
    ref.listen(messagesProvider(chatId), (_, _) => _markRead());
    final theme = Theme.of(context);
    final tokens = FamTokens.of(context);
    final canRecord = ref.watch(voiceRecordingSupportedProvider).value ?? false;
    final gifs = ref.watch(gifClientProvider).value;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    if (keyboard > 150) _keyboardHeight = keyboard;

    if (chat == null) {
      return Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: widget.showBack ? BackButton(onPressed: () => context.go('/')) : null,
        ),
        body: EmptyState(
          art: Icon(Icons.forum_outlined, size: 48, color: theme.colorScheme.onSurfaceVariant),
          title: 'This chat is no longer available.',
        ),
      );
    }
    final title = chatTitle(chat, members, users, me);
    final other = otherMember(chat, members, me);
    final group = chat.kind == 'group';
    // No family in common any more: the history stays, but nothing new can be sent.
    final readOnly = !group && other != null && users[other]?.former == true;
    _people = group
        ? {for (final m in members) if (m.userId != me && users[m.userId] != null) m.userId: users[m.userId]!.name}
        : const {};
    _canStartGame = !group && !readOnly && other != null;
    final active = group ? const <GameState>[] : activeGames(ref.watch(gamesProvider(chatId)));
    final otherOnline = other != null && online.contains(other);
    final subtitle = group ? membersLabel(members.length) : (otherOnline ? 'Online' : null);
    final resets = ref.watch(resetBannersProvider(chatId)).value ?? const <ResetRow>[];
    final changed = [
      for (final m in members)
        if (m.userId != me && users[m.userId] != null && users[m.userId]!.identityPub != users[m.userId]!.trustedIdentityPub)
          users[m.userId]!,
    ];

    final changes = _changes = messageChanges(messages);
    final reactions = aggregateReactions(messages);
    String nameOf(String userId) => userId == me ? 'You' : users[userId]?.name ?? 'Someone';
    // Plays, pokes, resigns and draw offers show as lines in the timeline.
    String firstNameOf(String userId) => nameOf(userId).split(' ').first;
    final gameEvents = gameEventsOf(
      messages,
      plays: ref.watch(gamePlaysProvider(chatId)),
      games: ref.watch(gamesProvider(chatId)),
      me: me,
      nameOf: firstNameOf,
      shown: (m) => !timelineHiddenKinds.contains(m.kind),
      readOnly: readOnly,
    );
    final visible =
        messages.where((m) => !timelineHiddenKinds.contains(m.kind) || gameEvents.containsKey(m.id)).toList();
    final byId = {for (final m in visible) m.id: m};
    QuotedMessage? quoteFor(MessageRow m) {
      final target = replyTargetOf(m);
      if (target == null) return null;
      final t = byId[target];
      return QuotedMessage(
        id: target,
        sender: t == null ? 'Someone' : nameOf(t.senderUserId),
        snippet: t == null ? 'Message not available' : messageSnippet(t, changes),
      );
    }

    final others = members.where((m) => m.userId != me).toList();
    // Ticks only on my messages since someone else last wrote: anything before their reply is read.
    final lastOtherSeq = visible.fold<int>(0, (top, m) => m.senderUserId != me && (m.seq ?? 0) > top ? m.seq! : top);
    ReadReceipt? receiptFor(MessageRow m) {
      if (m.senderUserId != me || m.seq == null || m.seq! <= lastOtherSeq) return null;
      return ReadReceipt(readBy: others.where((o) => o.lastReadSeq >= m.seq!).length, of: others.length);
    }

    final typingNames = [for (final u in typing) if (u != me) users[u]?.name ?? 'Someone'];
    final entries = buildTimeline(visible).reversed.toList(); // the list runs bottom-up
    final now = DateTime.now();
    final sync = ref.read(chatSyncProvider);
    const avatarSpace = 40.0;

    Widget entry(TimelineEntry e) => switch (e) {
          DayEntry(:final day) => DaySeparator(key: ValueKey('day-${day.millisecondsSinceEpoch}'), label: dayLabel(day, now)),
          MessageEntry(message: final m) when gameEvents.containsKey(m.id) => AppearIn(
              key: ValueKey(m.id),
              animate: _initialIds != null && !_initialIds!.contains(m.id) && _animated.add(m.id),
              child: KeyedSubtree(
                key: _keyFor(m.id),
                child: GameEventLine(
                  chatId: chatId,
                  gameId: gameEvents[m.id]!.gameId,
                  text: gameEvents[m.id]!.text,
                  suffix: gameEvents[m.id]!.suffix,
                  poke: gameEvents[m.id]!.poke,
                ),
              ),
            ),
          MessageEntry(message: final m) when m.kind == 'game' => AppearIn(
              key: ValueKey(m.id),
              animate: _initialIds != null && !_initialIds!.contains(m.id) && _animated.add(m.id),
              child: KeyedSubtree(
                key: _keyFor(m.id),
                child: GameCard(key: ValueKey(m.id), chatId: chatId, gameId: m.id),
              ),
            ),
          MessageEntry(message: final m, :final firstInGroup, :final lastInGroup) => AppearIn(
              key: ValueKey(m.id),
              animate: _initialIds != null && !_initialIds!.contains(m.id) && _animated.add(m.id),
              child: MessageBubble(
                key: _keyFor(m.id),
                message: m,
                shownText: changes.textOf(m),
                edited: changes.edited.contains(m.id),
                deleted: changes.isDeleted(m.id),
                quote: quoteFor(m),
                mentionNames: [for (final u in mentionsOf(m)) if (users[u] != null) users[u]!.name],
                linkPreview: changes.previewOf(m),
                onOpenQuote: replyTargetOf(m) == null ? null : () => _jumpTo(replyTargetOf(m)!),
                highlighted: _highlight == m.id,
                onReply: m.seq == null || changes.isDeleted(m.id) || !_replyable(m) ? null : () => _startReply(m),
                onForward: forwardableKinds.contains(m.kind) && m.body != null && !changes.isDeleted(m.id) ? () => _forward(m) : null,
                forwarded: isForwarded(m),
                onEdit: m.senderUserId == me && m.kind == 'text' && !changes.isDeleted(m.id) ? () => _startEdit(m) : null,
                onDelete: m.senderUserId == me && _replyable(m) && !changes.isDeleted(m.id) ? () => _delete(m) : null,
                mine: m.senderUserId == me,
                senderName: group && m.senderUserId != me && firstInGroup ? users[m.senderUserId]?.name ?? 'Someone' : null,
                reactions: reactions[m.id] ?? const {},
                myUserId: me,
                onReact: (e) => sync?.react(chatId, m.id, e),
                onRetry: () => sync?.retry(m.id),
                receipt: receiptFor(m),
                firstInGroup: firstInGroup,
                lastInGroup: lastInGroup,
                avatarSpace: group ? avatarSpace : 0,
                avatar: group && m.senderUserId != me && lastInGroup
                    ? PersonAvatar(label: users[m.senderUserId]?.name ?? '?', colorKey: m.senderUserId, userId: m.senderUserId, radius: 15)
                    : null,
              ),
            ),
        };

    return PopScope(
      // Back closes the emoji picker first, as it would the keyboard.
      canPop: !_pickerOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closePicker();
      },
      child: Scaffold(
        backgroundColor: tokens.chatBackdrop,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: widget.showBack ? BackButton(onPressed: () => context.go('/')) : null,
          titleSpacing: widget.showBack ? 0 : Space.lg,
          shape: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
          title: Row(children: [
            PersonAvatar(
              label: title,
              colorKey: group ? chat.id : (other ?? chat.id),
              userId: group ? null : other,
              group: group,
              online: otherOnline,
              radius: 20,
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  Flexible(child: Text(title, overflow: TextOverflow.ellipsis, maxLines: 1, style: theme.textTheme.titleMedium)),
                  if ((chat.mutedUntil ?? 0) > DateTime.now().millisecondsSinceEpoch) ...[
                    const SizedBox(width: 6),
                    Icon(
                      Icons.notifications_off_outlined,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                      semanticLabel: 'Muted',
                    ),
                  ],
                ]),
                if (subtitle != null)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
              ]),
            ),
          ]),
          actions: [
            IconButton(
              tooltip: 'Search in this chat ($shortcutModifier+F)',
              icon: const Icon(Icons.search_rounded),
              onPressed: () => context.go('/search?chat=$chatId'),
            ),
            IconButton(
              tooltip: 'Chat info',
              icon: const Icon(Icons.info_outline_rounded),
              onPressed: () => context.go('/chats/$chatId/info'),
            ),
            const SizedBox(width: Space.xs),
          ],
        ),
        body: _dropZone(LayoutBuilder(builder: (context, c) {
          // Wide panes keep the messages in a readable column; the backdrop runs edge to edge.
          final side = math.max(Space.md, (c.maxWidth - Widths.conversation) / 2);
          return Column(children: [
            for (final r in resets)
              NoticeCard(
                key: Key('reset-banner-${r.id}'),
                icon: Icons.restart_alt_rounded,
                text: resetBannerText(r, users),
                actions: [
                  TextButton(
                    key: Key('dismiss-reset-${r.id}'),
                    onPressed: () => ref.read(chatDbProvider).dismissResetBanner(r.id, chatId),
                    child: const Text('OK'),
                  ),
                ],
              ),
            for (final u in changed)
              NoticeCard(
                tone: NoticeTone.warning,
                icon: Icons.gpp_maybe_outlined,
                text: "${u.name}'s security key changed. This happens after an account reset.",
                actions: [
                  TextButton(
                    onPressed: () => ref.read(chatSyncProvider)?.acknowledgeIdentity(u.id),
                    style: TextButton.styleFrom(foregroundColor: theme.colorScheme.onErrorContainer),
                    child: const Text('OK'),
                  ),
                ],
              ),
            if (active.isNotEmpty) GameBar(chatId: chatId, games: active),
            Expanded(
              // Phones: a tap on the messages (not on a link or button in one) puts the keyboard
              // or emoji picker away.
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _touch ? _dismissInput : null,
                child: visible.isEmpty
                  ? EmptyState(
                      art: PersonAvatar(
                        label: title,
                        colorKey: group ? chat.id : (other ?? chat.id),
                        userId: group ? null : other,
                        group: group,
                        radius: 36,
                      ),
                      title: 'Say hello 👋',
                      body: group ? 'Messages here go to everyone in $title.' : 'Only you and $title can read this chat.',
                    )
                  : ListView.builder(
                      controller: _scroll,
                      reverse: true,
                      padding: EdgeInsets.fromLTRB(side, Space.sm, side, Space.sm),
                      itemCount: entries.length,
                      itemBuilder: (context, i) => entry(entries[i]),
                      // New messages go in at index 0 of this bottom-up list; matching keys to their new
                      // index keeps every other row (and its state) instead of rebuilding them all.
                      findChildIndexCallback: (key) {
                        final id = (key as ValueKey<Object?>).value;
                        final i = entries.indexWhere((e) => switch (e) {
                              MessageEntry(:final message) => message.id == id,
                              DayEntry(:final day) => 'day-${day.millisecondsSinceEpoch}' == id,
                            });
                        return i < 0 ? null : i;
                      },
                    ),
              ),
            ),
            if (typingNames.isNotEmpty)
              Padding(
                padding: EdgeInsets.fromLTRB(side + (group ? avatarSpace : 0), 0, side, Space.xs),
                child: Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: tokens.theirsBubble,
                      borderRadius: BorderRadius.circular(Radii.lg),
                      border: Border.all(color: tokens.theirsBorder),
                    ),
                    child: TypingDots(color: tokens.theirsMeta),
                  ),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: Text(
                      typingNames.length == 1
                          ? '${typingNames.single} is typing…'
                          : '${typingNames.join(', ')} are typing…',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ]),
              ),
            if (_suggesting && !_recording.active)
              Padding(
                padding: EdgeInsets.fromLTRB(side, 0, side, Space.xs),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: _mentioning
                        ? MentionSuggestions(people: _peopleMatches, selected: _selected, onPick: _pickPerson)
                        : ShortcodeSuggestions(matches: _matches, selected: _selected, onPick: _pickSuggestion),
                  ),
                ),
              ),
            if (_preparing > 0) const LinearProgressIndicator(key: Key('preparing-photo')),
            Material(
              color: theme.colorScheme.surface,
              shape: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
              child: SafeArea(
                top: false,
                child: readOnly
                    ? Padding(
                        key: const Key('no-shared-family'),
                        padding: EdgeInsets.symmetric(horizontal: side, vertical: Space.md),
                        child: Text(
                          "You're no longer in a family together",
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      )
                    : Column(mainAxisSize: MainAxisSize.min, children: [
                  if (_preview != null && _editing == null && !_recording.active)
                    Padding(
                      padding: EdgeInsets.fromLTRB(side, Space.sm, side, 0),
                      child: ComposerPreview(preview: _preview!, onRemove: _removePreview),
                    ),
                  if ((_replyTo != null || _editing != null) && !_recording.active)
                    Padding(
                      padding: EdgeInsets.fromLTRB(side, Space.sm, side, 0),
                      child: _ComposeBanner(
                        icon: _editing != null ? Icons.edit_outlined : Icons.reply_rounded,
                        title: _editing != null ? 'Editing message' : 'Replying to ${nameOf(_replyTo!.senderUserId)}',
                        snippet: messageSnippet((_editing ?? _replyTo)!, changes),
                        cancelTooltip: _editing != null ? 'Cancel edit' : 'Cancel reply',
                        onCancel: _cancelCompose,
                      ),
                    ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(math.max(Space.xs, side - Space.md), Space.sm, math.max(Space.sm, side - Space.xs), Space.sm),
                    child: _recording.active
                        ? RecordBar(recording: _recording, onDiscard: _recording.cancel, onSend: _finishRecording)
                        : emojiPopover
                            ? EmojiPopover(
                                handle: _emojiPopover,
                                onSelected: _insertEmoji,
                                gifs: _editing == null ? gifs : null,
                                onGif: _sendGif,
                                onClosed: () {
                                  if (mounted) _focus.requestFocus();
                                },
                                child: _composer(canRecord),
                              )
                            : _composer(canRecord),
                  ),
                  if (_pickerOpen && !_recording.active)
                    EmojiPanel(
                      height: _keyboardHeight.clamp(240.0, 360.0),
                      onSelected: _insertEmoji,
                      onBackspace: () => _text.value = deleteBackward(_text.value),
                      gifs: _editing == null ? gifs : null,
                      onGif: _sendGif,
                    ),
                ]),
              ),
            ),
          ]);
        })),
      ),
    );
  }
}

/// The attach menu's Game entry.
const _gameChoice = #game;

bool _replyable(MessageRow m) => const {'text', 'photo', 'voice', 'gif', 'video'}.contains(m.kind);

/// Above the composer while replying or editing: what, a snippet, and a close button.
/// Ctrl/Cmd+V in the composer: a photo or video on the clipboard is offered for sending; anything
/// else pastes as usual.
class _PasteMediaAction extends ContextAction<PasteTextIntent> {
  _PasteMediaAction(this.paste);

  final Future<void> Function(VoidCallback? otherwise) paste;

  @override
  Object? invoke(PasteTextIntent intent, [BuildContext? context]) {
    final usual = callingAction;
    unawaited(paste(() {
      if (usual is ContextAction<PasteTextIntent>) {
        usual.invoke(intent, context);
      } else {
        usual?.invoke(intent);
      }
    }));
    return null;
  }
}

class _ComposeBanner extends StatelessWidget {
  const _ComposeBanner({
    required this.icon,
    required this.title,
    required this.snippet,
    required this.cancelTooltip,
    required this.onCancel,
  });

  final IconData icon;
  final String title, snippet, cancelTooltip;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(Space.md, Space.xs, Space.xs, Space.xs),
      decoration: BoxDecoration(
        color: s.surfaceContainer,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border(left: BorderSide(color: s.tertiary, width: 3)),
      ),
      child: Row(children: [
        Icon(icon, size: 20, color: s.tertiary),
        const SizedBox(width: Space.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(title, style: theme.textTheme.labelLarge?.copyWith(color: s.tertiary, fontWeight: FontWeight.w700)),
            Text(snippet, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(color: s.onSurfaceVariant)),
          ]),
        ),
        IconButton(tooltip: cancelTooltip, icon: const Icon(Icons.close_rounded), onPressed: onCancel),
      ]),
    );
  }
}

/// "Mom's account was reset by Michael." (spec "Admin recovery"), or the recovery-code variant.
String resetBannerText(ResetRow r, Map<String, UserRow> users) {
  final who = users[r.userId]?.name ?? 'Someone';
  if (r.signerKind == 'recovery') {
    return '$who recovered their admin account with the recovery code. Their old devices were signed out.';
  }
  return "$who's account was reset by ${users[r.signerUserId]?.name ?? 'an admin'}. Their old devices were signed out.";
}
