import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/chat_sync.dart' show ReminderAfterExpiry;
import '../../chat/db/chat_db.dart';
import '../../chat/emoji/emoticons.dart';
import '../../chat/emoji/shortcodes.dart';
import '../../chat/files.dart' show fileOf;
import '../../chat/forward.dart';
import '../../transcripts/model_download_dialog.dart';
import '../../transcripts/transcripts_service.dart';
import '../../chat/mentions.dart';
import '../../chat/wire.dart' show FetchedPreview;
import '../../widgets/link_text.dart' show splitLinks;
import '../../chat/message_changes.dart';
import '../../chat/polls.dart' show PollState;
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
import '../../media/file_actions.dart';
import '../../media/send_files.dart';
import '../../media/media_service.dart';
import '../../media/photo_picker.dart';
import '../../media/send_media.dart';
import '../../chat/plaintext.dart';
import '../../media/staged_media.dart';
import '../../media/providers.dart';
import '../../voice/providers.dart';
import '../../voice/recording.dart';
import '../../voice/waveform.dart';
import '../../settings/time_format.dart' show lastSeenLabel;
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
import 'album_grid.dart';
import 'media_pager.dart';
import 'pin_bar.dart';
import 'file_bubble.dart' show saveFileMessage;
import 'disappearing_sheet.dart';
import 'scheduled_sheet.dart';
import 'time_picker_sheet.dart';
import 'poll_bubble.dart';
import 'poll_sheet.dart';
import 'staged_tray.dart';
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
  TranscriptsService? _transcriptsTarget;
  bool _empty = true;
  RecordingStatus _recStatus = RecordingStatus.idle;

  /// Phones: the emoji picker is showing in place of the keyboard.
  bool _pickerOpen = false;

  /// The last on-screen keyboard height, so the picker can take its place at the same size.
  double _keyboardHeight = 300;

  /// Desktop and web: the emoji popover.
  final _emojiPopover = EmojiPopoverHandle();

  /// Poll id → (my picks as the fold showed them when I tapped, the picks I sent): until the fold
  /// moves off the former, quick taps build on what was sent rather than on the stale fold.
  final _sentVotes = <String, (List<int>, List<int>)>{};

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

  /// "Schedule message" picked with nothing to send yet: the next thing sent (text, photos, voice,
  /// a file, a poll, a GIF) is scheduled for this time instead.
  DateTime? _scheduleAt;

  /// The schedule time for a send now (null: send at once), clearing the schedule mode. Says so
  /// and returns false when that time has passed meanwhile.
  bool _takeSchedule(void Function(DateTime? at) send) {
    final at = _scheduleAt;
    if (at != null) {
      final sync = ref.read(chatSyncProvider);
      setState(() => _scheduleAt = null);
      if (sync != null && !sync.canScheduleAt(at)) {
        _snack('That time is too close now. Pick another.');
        return false;
      }
    }
    send(at);
    return true;
  }

  /// "Scheduled for Tomorrow at 9:00 AM".
  void _scheduledSnack(DateTime at) {
    if (mounted) _snack('Scheduled for ${whenLabel(at, h24: MediaQuery.alwaysUse24HourFormatOf(context))}');
  }

  /// Long-press (touch) or right-click (desktop, web) on Send or the mic: "Schedule message".
  Future<void> _scheduleMenu(Offset? global) async {
    if (_editing != null) return;
    final bool picked;
    if (global != null) {
      final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
      picked = await showMenu<bool>(
            context: context,
            position: RelativeRect.fromRect(global & Size.zero, Offset.zero & overlay.size),
            items: const [
              PopupMenuItem(
                key: Key('schedule-message'),
                value: true,
                child: ListTile(leading: Icon(Icons.schedule_send_outlined), title: Text('Schedule message')),
              ),
            ],
          ) ??
          false;
    } else {
      picked = await showModalBottomSheet<bool>(
            context: context,
            builder: (context) => SafeArea(
              child: ListTile(
                key: const Key('schedule-message'),
                leading: const Icon(Icons.schedule_send_outlined),
                title: const Text('Schedule message'),
                onTap: () => Navigator.pop(context, true),
              ),
            ),
          ) ??
          false;
    }
    if (!picked || !mounted) return;
    final at = await pickTime(context, title: 'Schedule message');
    if (at == null || !mounted) return;
    setState(() => _scheduleAt = at);
    // Something to send already: it goes (scheduled) now. Otherwise the next send is.
    final hasContent = _text.text.trim().isNotEmpty || ref.read(stagedMediaProvider(widget.chatId)).isNotEmpty;
    if (hasContent) await _send();
  }

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
    unawaited(_loadReadPosition());
    _webPaste = listenForPastedFiles(() => mounted && _focus.hasFocus, (files) async {
      final sorted = await pickedFromFiles(files);
      _stage(sorted.media);
    });
  }

  /// Where I had read up to when the chat opened (from my join point), before this view marks it read.
  int? _readAtOpen;
  final _openedAt = DateTime.now();

  /// The first message that was unread on opening: the "New messages" line goes above it. Looked
  /// for until found, for a few seconds after opening (a catch-up may bring the unread ones).
  String? _unreadFrom;
  bool _unreadScrolled = false;
  final _unreadKey = GlobalKey();

  /// Read before the first frame, so before this view's own mark-read can move it.
  Future<void> _loadReadPosition() async {
    final db = ref.read(chatDbProvider);
    final me = ref.read(myUserIdProvider);
    final chat = await db.chatById(widget.chatId);
    final joined = (await db.membersOf(widget.chatId)).where((m) => m.userId == me).firstOrNull?.joinedSeq ?? 0;
    if (!mounted || chat == null) return;
    setState(() => _readAtOpen = math.max(chat.myLastReadSeq, joined));
  }

  void _findUnread(List<MessageRow> visible, String? me) {
    final read = _readAtOpen;
    if (_unreadFrom != null || read == null || widget.jumpTo != null) return;
    if (DateTime.now().difference(_openedAt) > const Duration(seconds: 5)) return;
    _unreadFrom = visible.where((m) => m.senderUserId != me && m.kind != 'pin' && m.seq != null && m.seq! > read).firstOrNull?.id;
    if (_unreadFrom != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_scrollToUnread());
      });
    }
  }

  /// Brings the "New messages" line into view when it's above the screen, near the top.
  Future<void> _scrollToUnread() async {
    if (_unreadScrolled) return;
    _unreadScrolled = true;
    for (var i = 0; i < 60; i++) {
      final ctx = _unreadKey.currentContext;
      if (ctx != null && ctx.mounted) {
        final box = ctx.findRenderObject() as RenderBox?;
        final viewport = _scroll.hasClients ? _scroll.position.context.storageContext.findRenderObject() as RenderBox? : null;
        if (box != null && viewport != null) {
          final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
          if (top >= 0) return; // already on screen
        }
        await Scrollable.ensureVisible(ctx, alignment: 0.9);
        return;
      }
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      if (pos.pixels >= pos.maxScrollExtent) return;
      _scroll.jumpTo(math.min(pos.pixels + pos.viewportDimension * 0.8, pos.maxScrollExtent));
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  /// Who of the chat's other members has read [m] (mine, sent).
  Future<void> _showReaders(MessageRow m, List<MemberRow> members, Map<String, UserRow> users, String? me) async {
    final others = members.where((o) => o.userId != me).toList()
      ..sort((a, b) => (users[a.userId]?.name ?? '').compareTo(users[b.userId]?.name ?? ''));
    final read = [for (final o in others) if (o.lastReadSeq >= (m.seq ?? 1 << 62)) o];
    final unread = [for (final o in others) if (o.lastReadSeq < (m.seq ?? 1 << 62)) o];
    Widget person(MemberRow o) => ListTile(
          leading: PersonAvatar(label: users[o.userId]?.name ?? '?', colorKey: o.userId, userId: o.userId, radius: 16),
          title: Text(users[o.userId]?.name ?? 'Someone'),
        );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        final theme = Theme.of(context);
        Widget heading(String text) => Padding(
              padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.xs),
              child: Text(text, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            );
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
            child: ListView(shrinkWrap: true, key: const Key('readers-sheet'), children: [
              heading(read.isEmpty ? 'Read by nobody yet' : 'Read by'),
              for (final o in read) person(o),
              if (unread.isNotEmpty) ...[heading('Not read yet'), for (final o in unread) person(o)],
              const SizedBox(height: Space.sm),
            ]),
          ),
        );
      },
    );
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
    final people = mq == null || dismissed ? const <Person>[] : mentionSuggestionsFor(mq.query, _people).take(6).toList();
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
    _stage(media);
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
    _transcriptsTarget = ref.read(transcriptsServiceProvider);
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
    final transcripts = _transcriptsTarget;
    if (media == null) {
      _snack("Couldn't send that voice message.");
      return;
    }
    try {
      final at = _scheduleAt;
      if (at != null) {
        if (mounted) setState(() => _scheduleAt = null);
        if (!media.sync.canScheduleAt(at)) {
          _snack('That time is too close now. Pick another.');
          return;
        }
        await media.sendVoice(widget.chatId, clip, at: at);
        _scheduledSnack(at);
        return;
      }
      final id = await media.sendVoice(widget.chatId, clip);
      // The transcript follows the clip; it never holds it up.
      unawaited(transcripts?.afterVoiceSent(widget.chatId, id, clip, scheduled: false));
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
    final editing = _editing, replyTo = _replyTo;
    final hasStaged = ref.read(stagedMediaProvider(widget.chatId)).isNotEmpty;
    // Scheduled (see [_scheduleAt]) unless editing; nothing to send keeps the schedule waiting.
    DateTime? at;
    if (editing == null && (hasStaged || text.trim().isNotEmpty) && _scheduleAt != null) {
      if (!_takeSchedule((t) => at = t)) return;
    }
    if (editing == null && hasStaged) {
      if (text.trim().runes.length > maxTextLength) {
        _snack('That message is too long.');
        return;
      }
      await _sendStaged(text, replyTo, at: at);
      if (at != null) _scheduledSnack(at!);
      if (!_pickerOpen && mounted) _focus.requestFocus();
      return;
    }
    if (sync == null || text.trim().isEmpty) return;
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
              replyTo: replyTo?.id, mentions: mentionsIn(text, _people), at: at);
        } else {
          // Its preview may still be on the way (the wait above is short): attach it once it comes.
          // (Not to a scheduled one: the server holds that one as it is.)
          final late = at == null && link != null && link == _previewUrl && link != _dismissedPreviewUrl ? _previewFetch : null;
          final id = await sync.sendText(widget.chatId, text, replyTo: replyTo?.id, mentions: mentionsIn(text, _people), at: at);
          if (late != null && media != null) unawaited(media.attachLatePreview(widget.chatId, id, late));
        }
        if (at != null) _scheduledSnack(at!);
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

  /// Whether pin event [m] pins (else unpins).
  static bool _pinned(MessageRow m) {
    try {
      return (jsonDecode(m.body!) as Map)['pinned'] == true;
    } catch (_) {
      return false;
    }
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

  /// Deletes [ms] (a message, or an album's items) for everyone, after asking.
  Future<void> _delete(List<MessageRow> ms) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(ms.length == 1 ? 'Delete for everyone?' : 'Delete these ${ms.length} for everyone?'),
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
    for (final m in ms) {
      if (_editing?.id == m.id || _replyTo?.id == m.id) _cancelCompose();
      await ref.read(chatSyncProvider)?.deleteMessage(widget.chatId, m.id);
    }
  }

  /// Forwards [ms] (a message, or an album's items) to a chat picked.
  Future<void> _forward(List<MessageRow> ms) async {
    final to = await showForwardPicker(context, fromChatId: widget.chatId);
    if (to == null || !mounted) return;
    final sync = ref.read(chatSyncProvider);
    if (sync == null) return;
    try {
      for (final m in ms) {
        await forwardMessage(
          message: m,
          changes: _changes,
          toChatId: to.id,
          sync: sync,
          media: ref.read(mediaServiceProvider),
        );
      }
      _snack('Forwarded to ${to.title}');
    } on ForwardException catch (e) {
      _snack(e.reason == 'media expired' ? "That's no longer available to forward." : "That message can't be forwarded.");
    } catch (_) {
      _snack("Couldn't forward that message.");
    }
  }

  /// "Remind me" on [m] (a time, then set), or with a reminder already at [current]: change or
  /// clear it.
  Future<void> _remind(MessageRow m, int? current) async {
    final sync = ref.read(chatSyncProvider);
    if (sync == null) return;
    final h24 = MediaQuery.alwaysUse24HourFormatOf(context);
    if (current != null) {
      final choice = await showModalBottomSheet<String>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: const Text('Reminder'),
              subtitle: Text(whenLabel(DateTime.fromMillisecondsSinceEpoch(current), h24: h24)),
            ),
            ListTile(
              key: const Key('reminder-change'),
              leading: const Icon(Icons.schedule_rounded),
              title: const Text('Change time'),
              onTap: () => Navigator.pop(context, 'change'),
            ),
            ListTile(
              key: const Key('reminder-clear'),
              leading: const Icon(Icons.notifications_off_outlined),
              title: const Text('Clear reminder'),
              onTap: () => Navigator.pop(context, 'clear'),
            ),
          ]),
        ),
      );
      if (choice == null || !mounted) return;
      if (choice == 'clear') {
        try {
          await sync.clearReminder(widget.chatId, m.id);
          _snack('Reminder cleared');
        } catch (_) {
          _snack("Couldn't clear the reminder. Check your connection.");
        }
        return;
      }
    }
    final at = await pickTime(context, title: current == null ? 'Remind me' : 'Change reminder');
    if (at == null || !mounted) return;
    try {
      await sync.setReminder(widget.chatId, m.id, at);
      _snack('Reminder set for ${whenLabel(at, h24: h24)}');
    } on ArgumentError {
      _snack('That time is too close now. Pick another.');
    } on ReminderAfterExpiry catch (e) {
      _snack('This message disappears before then (${whenLabel(e.expiresAt, h24: h24)}). Pick an earlier time.');
    } catch (_) {
      _snack("Couldn't set the reminder. Check your connection.");
    }
  }

  /// Album items other than the last have no bubble of their own: jumps go to their album's.
  Map<String, String> _albumOwner = const {};

  /// Scrolls until [id]'s bubble is built, centers it and tints it for a moment.
  Future<void> _jumpTo(String target) async {
    final id = _albumOwner[target] ?? target;
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
    DateTime? at;
    if (!_takeSchedule((t) => at = t)) return;
    if (at case final at?) {
      await sync.scheduleMessage(widget.chatId, picked.body, at);
      _scheduledSnack(at);
    } else {
      await sync.enqueueMessage(widget.chatId, picked.body);
    }
    if (client != null) unawaited(client.share(picked.slug));
  }

  /// Photos and videos being compressed and encrypted (before they appear in the list).
  int _preparing = 0;

  /// Files are being dragged over the conversation (desktop and web).
  bool _dragging = false;

  /// Photos and videos dropped on the conversation wait in the tray; other files are sent as they
  /// are (folders can't be).
  Widget _dropZone(Widget child) {
    final theme = Theme.of(context);
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) async {
        setState(() => _dragging = false);
        final dropped = details.files.whereType<DropItemFile>().toList();
        final sorted = await pickedFromFiles(dropped);
        if (details.files.length > dropped.length) _snack("Folders can't be sent. Drop the files in them.");
        _stage(sorted.media);
        await _sendFiles([for (final f in sorted.others) OutgoingFile.xfile(f)]);
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
                    Text('Drop files to send',
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

  /// Opens the new-poll sheet; the poll replies to the message being replied to, if any.
  Future<void> _startPoll() async {
    final replyTo = _editing == null ? _replyTo : null;
    final at = _scheduleAt;
    try {
      final id = await showNewPollSheet(context, widget.chatId, replyTo: replyTo?.id, at: at);
      if (id != null && at != null && mounted) {
        setState(() => _scheduleAt = null);
        _scheduledSnack(at);
      }
      if (id != null && mounted && replyTo != null && _replyTo?.id == replyTo.id) setState(() => _replyTo = null);
    } catch (_) {
      _snack("Couldn't send the poll.");
    }
  }

  /// Sends [files] as they are, each its own message; the first replies to the message being replied
  /// to, if any. Says which were too large.
  Future<void> _sendFiles(List<OutgoingFile> files) async {
    final media = ref.read(mediaServiceProvider);
    if (files.isEmpty || media == null || !mounted) return;
    final replyTo = _editing == null ? _replyTo : null;
    DateTime? at;
    if (!_takeSchedule((t) => at = t)) return;
    setState(() => _preparing++);
    final FileSendReport report;
    try {
      report = await sendFiles(media, widget.chatId, files, replyTo: replyTo?.id, at: at);
    } finally {
      if (mounted) setState(() => _preparing--);
    }
    if (at != null && report.sent > 0) _scheduledSnack(at!);
    if (report.sent > 0 && mounted && replyTo != null && _replyTo?.id == replyTo.id) setState(() => _replyTo = null);
    if (report.problem case final p?) _snack(p);
  }

  /// Opens the file picker (any type, several at once) and sends what's picked.
  Future<void> _pickFiles() async {
    final List<OutgoingFile> picked;
    try {
      picked = await ref.read(filePickerProvider)();
    } catch (_) {
      _snack("Couldn't open the picker.");
      return;
    }
    await _sendFiles(picked);
  }

  /// The "+" menu: the library, the camera where there is one, File, Poll, and Game where one can start. Phones
  /// show it as a sheet; desktop and web as a menu by the button ([anchor]'s context).
  Future<void> _attach(BuildContext anchor) async {
    final items = <(IconData, String, Object)>[
      (Icons.photo_library_outlined, 'Photos and videos', PickSource.library),
      if (cameraAvailable) ...[
        (Icons.photo_camera_outlined, 'Take a photo', PickSource.camera),
        (Icons.videocam_outlined, 'Record a video', PickSource.cameraVideo),
      ],
      (Icons.attach_file_rounded, 'File', _fileChoice),
      (Icons.poll_outlined, 'Poll', _pollChoice),
      if (_canStartGame) (Icons.casino_outlined, 'Game', _gameChoice),
    ];
    // A PickSource, [_fileChoice], [_pollChoice] or [_gameChoice].
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
    if (choice == _pollChoice) {
      if (mounted) await _startPoll();
      return;
    }
    if (choice == _fileChoice) {
      if (mounted) await _pickFiles();
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
    _stage(picked);
  }

  /// Puts photos and videos in the tray above the composer, to go with the next Send.
  void _stage(List<PickedMedia> items) {
    if (items.isEmpty || !mounted) return;
    final left = ref.read(stagedMediaProvider(widget.chatId).notifier).add(items);
    if (left > 0) _snack('You can send up to $maxStagedMedia photos and videos at once.');
    if (!_touch) _focus.requestFocus();
  }

  /// Sends the staged photos and videos, each its own message, with [caption] (and the reply and
  /// its @mentions) on the last; says which couldn't be sent.
  Future<void> _sendStaged(String caption, MessageRow? replyTo, {DateTime? at}) async {
    final media = ref.read(mediaServiceProvider);
    final staged = ref.read(stagedMediaProvider(widget.chatId).notifier);
    final picked = ref.read(stagedMediaProvider(widget.chatId));
    if (media == null || picked.isEmpty) return;
    staged.clear();
    _text.clear();
    setState(() => _replyTo = null);
    _saveDraftNow();
    final report = await sendMedia(
      media,
      ref.read(videoProcessorProvider),
      widget.chatId,
      picked,
      caption: caption,
      replyTo: replyTo?.id,
      mentions: mentionsIn(caption, _people),
      at: at,
      onStart: () {
        if (mounted) setState(() => _preparing++);
      },
      onEnd: () {
        if (mounted) setState(() => _preparing--);
      },
    );
    if (report.problem case final p?) _snack(p);
  }

  /// Transcribe in the menu: on this device, after offering the model download if it's missing.
  Future<void> _transcribe(MessageRow m) async {
    final service = ref.read(transcriptsServiceProvider);
    if (service == null || !await ensureTranscriptModel(context, ref) || !mounted) return;
    switch (await service.transcribeMessage(m)) {
      case TranscribeOutcome.done:
        break;
      case TranscribeOutcome.noSpeech:
        _snack('No speech found in that voice message.');
      case TranscribeOutcome.gone:
        _snack('That voice message is no longer available.');
      case TranscribeOutcome.failed:
        _snack("Couldn't transcribe that voice message.");
    }
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
                  _stage([PickedPhoto(bytes)]);
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
      else if (_empty && canRecord && ref.watch(stagedMediaProvider(widget.chatId)).isEmpty)
        _scheduleGestures(IconButton.filled(
          tooltip: 'Record voice message',
          style: IconButton.styleFrom(fixedSize: const Size.square(48)),
          icon: const Icon(Icons.mic_rounded),
          onPressed: _startRecording,
        ))
      else
        _scheduleGestures(IconButton.filled(
          tooltip: _scheduleAt == null ? 'Send' : 'Schedule',
          style: IconButton.styleFrom(fixedSize: const Size.square(48)),
          icon: Icon(_scheduleAt == null ? Icons.arrow_upward_rounded : Icons.schedule_send_rounded),
          onPressed: _send,
        )),
    ]);
  }

  /// Send (or the mic) with "Schedule message" on a long-press or right-click. The button's own
  /// tooltip then shows on hover only: on touch its long-press would win over this one.
  Widget _scheduleGestures(Widget button) => GestureDetector(
        onLongPress: () => unawaited(_scheduleMenu(null)),
        onSecondaryTapUp: (d) => unawaited(_scheduleMenu(d.globalPosition)),
        child: TooltipTheme(
          data: TooltipTheme.of(context).copyWith(triggerMode: TooltipTriggerMode.manual),
          child: button,
        ),
      );

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
    final otherSeen = other == null ? null : users[other]?.lastSeenAt;
    final subtitle = group
        ? membersLabel(members.length)
        : otherOnline
        ? 'Online'
        : otherSeen == null
        ? null
        : lastSeenLabel(DateTime.fromMillisecondsSinceEpoch(otherSeen), h24: MediaQuery.alwaysUse24HourFormatOf(context));
    final resets = ref.watch(resetBannersProvider(chatId)).value ?? const <ResetRow>[];
    final changed = [
      for (final m in members)
        if (m.userId != me && users[m.userId] != null && users[m.userId]!.identityPub != users[m.userId]!.trustedIdentityPub)
          users[m.userId]!,
    ];

    final changes = _changes = messageChanges(messages);
    // The chat's photos and videos, oldest first: the viewer steps through them.
    final media = [
      for (final m in messages)
        if (captionKinds.contains(m.kind) && !changes.isDeleted(m.id) && m.body != null) m,
    ];
    void openMedia(MessageRow m) {
      final i = media.indexWhere((x) => x.id == m.id);
      if (i >= 0) showMediaPager(context, media, i);
    }
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
    // Pins and unpins show as lines too.
    final pinNotes = {for (final r in changes.pinEvents) r.id: r};
    final pinnedIds = changes.pinned.toSet();
    final starred = {for (final st in ref.watch(starsProvider(chatId)).value ?? const <StarRow>[]) st.messageId};
    final reminders = ref.watch(remindersProvider(chatId)).value ?? const <String, int>{};
    final localTranscripts = kIsWeb ? const <String, String>{} : ref.watch(localTranscriptsProvider(chatId)).value ?? const <String, String>{};
    final transcribingIds = kIsWeb ? const <String>{} : ref.watch(transcribingProvider).value ?? const <String>{};
    final canTranscribe = !kIsWeb && ref.watch(transcriptsServiceProvider) != null;
    final polls = ref.watch(pollsProvider(chatId));
    Widget? pollIn(MessageRow m) {
      final PollState? state = m.kind == 'poll' ? polls[m.id] : null;
      if (state == null) return null;
      final open = m.state != 'failed' && !readOnly && !state.ended;
      final folded = me == null ? const <int>[] : state.mine(me);
      final sent = _sentVotes[m.id];
      if (sent != null && !listEquals(sent.$1, folded)) _sentVotes.remove(m.id);
      return PollBubble(
        row: m,
        state: state,
        me: me,
        mine: m.senderUserId == me,
        nameOf: (u) => users[u]?.name ?? '?',
        picked: _sentVotes[m.id]?.$2,
        onVote: open
            ? (choices) {
                setState(() => _sentVotes[m.id] = (_sentVotes[m.id]?.$1 ?? folded, choices));
                ref.read(chatSyncProvider)?.vote(chatId, m.id, choices);
              }
            : null,
        onEnd: open && m.senderUserId == me && m.seq != null ? () => ref.read(chatSyncProvider)?.endPoll(chatId, m.id) : null,
        onSeeVotes: () => showPollVotesSheet(context, chatId: chatId, pollId: m.id, initial: state, members: members, users: users, me: me),
      );
    }
    final visible = messages
        .where((m) => !timelineHiddenKinds.contains(m.kind) || gameEvents.containsKey(m.id) || pinNotes.containsKey(m.id))
        .toList();
    final byId = {for (final m in visible) m.id: m};
    final byIdAll = {for (final m in messages) m.id: m};
    // A message being replied to or edited may disappear meanwhile (its timer, or the server).
    if (loaded.hasValue && [_replyTo, _editing].any((m) => m != null && !byIdAll.containsKey(m.id))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_editing != null && !byIdAll.containsKey(_editing!.id)) _endEdit();
        if (_replyTo != null && !byIdAll.containsKey(_replyTo!.id)) setState(() => _replyTo = null);
      });
    }
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
    _findUnread(visible, me);
    final noteText = disappearNoteText(chat, nameOf);
    final timeline = buildTimeline(
      visible,
      unreadFrom: _unreadFrom,
      albumOf: (m) => changes.isDeleted(m.id) ? null : albumIdOf(m),
      note: noteText == null ? null : NoteEntry(chat.disappearChangedSeq!, noteText),
    );
    _albumOwner = {
      for (final e in timeline.whereType<AlbumEntry>())
        for (final m in e.items) m.id: e.items.last.id,
    };
    final entries = timeline.reversed.toList(); // the list runs bottom-up // the list runs bottom-up
    final now = DateTime.now();
    final sync = ref.read(chatSyncProvider);
    const avatarSpace = 40.0;

    Widget bubble(MessageRow m, {required bool firstInGroup, required bool lastInGroup, List<MessageRow>? album}) =>
        AppearIn(
              key: ValueKey(m.id),
              animate: _initialIds != null && !_initialIds!.contains(m.id) && _animated.add(m.id),
              child: MessageBubble(
                key: _keyFor(m.id),
                message: m,
                album: album,
                onOpenAlbumItem: album == null ? null : (i) => openMedia(album[i]),
                onOpenMedia: captionKinds.contains(m.kind) ? () => openMedia(m) : null,
                shownText: changes.textOf(m),
                edited: changes.edited.contains(m.id),
                deleted: changes.isDeleted(m.id),
                quote: quoteFor(m),
                mentionNames: [
                  for (final u in mentionsOf(m)) if (users[u] != null) users[u]!.name,
                  if (group && mentionsOf(m).isNotEmpty) everyoneName,
                ],
                linkPreview: changes.previewOf(m),
                // The sender's transcript wins over one made here.
                transcript: changes.transcriptOf(m) ?? (changes.isDeleted(m.id) ? null : localTranscripts[m.id]),
                localTranscript: changes.transcriptOf(m) == null && localTranscripts.containsKey(m.id),
                transcribing: transcribingIds.contains(m.id),
                onTranscribe: canTranscribe &&
                        m.kind == 'voice' &&
                        !changes.isDeleted(m.id) &&
                        changes.transcriptOf(m) == null &&
                        !localTranscripts.containsKey(m.id) &&
                        !transcribingIds.contains(m.id)
                    ? () => unawaited(_transcribe(m))
                    : null,
                custom: pollIn(m),
                onOpenQuote: replyTargetOf(m) == null ? null : () => _jumpTo(replyTargetOf(m)!),
                highlighted: _highlight == m.id,
                onReply: m.seq == null || changes.isDeleted(m.id) || !_replyable(m) ? null : () => _startReply(m),
                onForward: (album ?? [m]).every((i) => forwardableKinds.contains(i.kind) && i.body != null && !changes.isDeleted(i.id))
                    ? () => _forward(album ?? [m])
                    : null,
                forwarded: isForwarded(m),
                onSave: switch (changes.isDeleted(m.id) ? null : fileOf(m)) {
                  final f? => () => saveFileMessage(context, ref, f),
                  null => null,
                },
                onEdit: m.senderUserId == me && changes.textOf(m) != null ? () => _startEdit(m) : null,
                onDelete: m.senderUserId == me && _replyable(m) && !changes.isDeleted(m.id) ? () => _delete(album ?? [m]) : null,
                // An album counts as pinned when any of its items is; unpinning unpins those.
                pinned: (album ?? [m]).any((i) => pinnedIds.contains(i.id)),
                onPin: m.seq == null || changes.isDeleted(m.id) || readOnly
                    ? null
                    : () {
                        final pinnedItems = [for (final i in album ?? [m]) if (pinnedIds.contains(i.id)) i.id];
                        if (pinnedItems.isEmpty) {
                          sync?.pinMessage(chatId, m.id, pinned: true);
                        } else {
                          for (final id in pinnedItems) {
                            sync?.pinMessage(chatId, id, pinned: false);
                          }
                        }
                      },
                starred: starred.contains(m.id),
                reminderAt: reminders[m.id],
                onRemind: m.seq == null || changes.isDeleted(m.id) ? null : () => unawaited(_remind(m, reminders[m.id])),
                onStar: m.seq == null || changes.isDeleted(m.id)
                    ? null
                    : () => sync?.star(chatId, m.id, starred: !starred.contains(m.id)),
                onReadBy: group && m.senderUserId == me && m.seq != null && others.isNotEmpty
                    ? () => _showReaders(m, members, users, me)
                    : null,
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
            );

    Widget entry(TimelineEntry e) => switch (e) {
          DayEntry(:final day) => DaySeparator(key: ValueKey('day-${day.millisecondsSinceEpoch}'), label: dayLabel(day, now)),
          UnreadEntry() => KeyedSubtree(key: const ValueKey('unread-line'), child: UnreadDivider(key: _unreadKey)),
          NoteEntry(:final text) =>
            DisappearNoteLine(key: const ValueKey('disappear-note'), text: text, on: chat.disappearSecs != null),
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
          MessageEntry(message: final m) when pinNotes.containsKey(m.id) => AppearIn(
              key: ValueKey(m.id),
              animate: _initialIds != null && !_initialIds!.contains(m.id) && _animated.add(m.id),
              child: KeyedSubtree(
                key: _keyFor(m.id),
                child: PinNoteLine(
                  text: '${nameOf(m.senderUserId)} ${_pinned(m) ? 'pinned' : 'unpinned'} a message',
                  onTap: () => _jumpTo(m.targetId!),
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
          MessageEntry(message: final m, :final firstInGroup, :final lastInGroup) =>
            bubble(m, firstInGroup: firstInGroup, lastInGroup: lastInGroup),
          AlbumEntry(:final items, :final firstInGroup, :final lastInGroup) =>
            bubble(items.last, firstInGroup: firstInGroup, lastInGroup: lastInGroup, album: items),
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
              chatId: chat.id,
              chatPhotoKey: chat.avatarKey,
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
                  if (chat.disappearSecs != null) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: 'Disappearing messages: ${disappearLabel(chat.disappearSecs)}',
                      child: Icon(
                        Icons.timer_outlined,
                        key: const Key('disappearing-icon'),
                        size: 16,
                        color: theme.colorScheme.onSurfaceVariant,
                        semanticLabel: 'Disappearing messages: ${disappearLabel(chat.disappearSecs)}',
                      ),
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
            PopupMenuButton<String>(
              key: const Key('chat-menu'),
              tooltip: 'More',
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (v) => switch (v) {
                'disappearing' => unawaited(changeDisappearing(context, ref, chat)),
                'media' => context.go('/chats/$chatId/media'),
                _ => null,
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  key: const Key('chat-menu-disappearing'),
                  value: 'disappearing',
                  child: ListTile(
                    leading: Icon(chat.disappearSecs == null ? Icons.timer_off_outlined : Icons.timer_outlined),
                    title: const Text('Disappearing messages'),
                    subtitle: Text(disappearLabel(chat.disappearSecs)),
                  ),
                ),
                const PopupMenuItem(
                  value: 'media',
                  child: ListTile(leading: Icon(Icons.photo_library_outlined), title: Text('Media, links and starred')),
                ),
              ],
            ),
            const SizedBox(width: Space.xs),
          ],
        ),
        body: _dropZone(LayoutBuilder(builder: (context, c) {
          // Wide panes keep the messages in a readable column; the backdrop runs edge to edge.
          final side = math.max(Space.md, (c.maxWidth - Widths.conversation) / 2);
          return Column(children: [
            if (changes.pinned.isNotEmpty)
              PinBar(
                pins: changes.pinned,
                snippetOf: (id) => byIdAll[id] == null ? 'Message' : messageSnippet(byIdAll[id]!, changes),
                onJump: (id) => unawaited(_jumpTo(id)),
              ),
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
                child: entries.isEmpty
                  ? EmptyState(
                      art: PersonAvatar(
                        label: title,
                        colorKey: group ? chat.id : (other ?? chat.id),
                        userId: group ? null : other,
                        group: group,
                        chatId: chat.id,
                        chatPhotoKey: chat.avatarKey,
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
                              AlbumEntry(:final items) => items.last.id == id,
                              DayEntry(:final day) => 'day-${day.millisecondsSinceEpoch}' == id,
                              UnreadEntry() => id == 'unread-line',
                              NoteEntry() => id == 'disappear-note',
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
            ScheduledBar(chatId: chatId, mentionsOf: (text) => mentionsIn(text, _people)),
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
                  if (ref.watch(stagedMediaProvider(chatId)) case final staged
                      when staged.isNotEmpty && _editing == null && !_recording.active)
                    Padding(
                      padding: EdgeInsets.fromLTRB(side, Space.xs, side, 0),
                      child: Builder(
                        builder: (context) => StagedTray(
                          items: staged,
                          onRemove: ref.read(stagedMediaProvider(chatId).notifier).removeAt,
                          onAdd: () => _attach(context),
                        ),
                      ),
                    ),
                  // A link card can't go with photos, so none while they wait.
                  if (_preview != null && _editing == null && !_recording.active && ref.watch(stagedMediaProvider(chatId)).isEmpty)
                    Padding(
                      padding: EdgeInsets.fromLTRB(side, Space.sm, side, 0),
                      child: ComposerPreview(preview: _preview!, onRemove: _removePreview),
                    ),
                  if (_scheduleAt case final at? when _editing == null)
                    Padding(
                      padding: EdgeInsets.fromLTRB(side, Space.sm, side, 0),
                      child: _ComposeBanner(
                        key: const Key('schedule-banner'),
                        icon: Icons.schedule_send_outlined,
                        title: 'Scheduling for ${whenLabel(at, h24: MediaQuery.alwaysUse24HourFormatOf(context))}',
                        snippet: _recording.active ? 'This voice message waits until then.' : 'What you send next waits until then.',
                        cancelTooltip: 'Cancel scheduling',
                        onCancel: () => setState(() => _scheduleAt = null),
                      ),
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
                    // Keyed: banners coming and going above must not rebuild the field, which would
                    // keep its focus but lose the keyboard (on desktop, typing went nowhere).
                    key: const ValueKey('composer-row'),
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

/// The attach menu's Game, Poll and File entries.
const _gameChoice = #game, _pollChoice = #poll, _fileChoice = #file;

bool _replyable(MessageRow m) => const {'text', 'photo', 'voice', 'gif', 'video', 'poll', 'file'}.contains(m.kind);

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
    super.key,
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
