// Making a poll: the "+" menu's Poll opens this sheet (docs/protocol.md "Polls").
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/plaintext.dart';
import '../../chat/providers.dart';
import '../../theme/tokens.dart';

/// Shows the new-poll sheet for [chatId] and sends the poll made there, replying to [replyTo] if
/// set. Returns the poll's id, or null when the sheet was closed without sending.
Future<String?> showNewPollSheet(BuildContext context, String chatId, {String? replyTo}) async {
  final poll = await showModalBottomSheet<PollBody>(
    context: context,
    isScrollControlled: true,
    builder: (context) => NewPollSheet(replyTo: replyTo),
  );
  if (poll == null || !context.mounted) return null;
  final sync = ProviderScope.containerOf(context, listen: false).read(chatSyncProvider);
  return sync?.sendPoll(chatId, poll);
}

/// The sheet's body: question, 2–[maxPollOptions] options and the multiple-answer switch. Pops with
/// the poll once [validPoll] accepts it.
class NewPollSheet extends StatefulWidget {
  const NewPollSheet({super.key, this.replyTo});

  final String? replyTo;

  @override
  State<NewPollSheet> createState() => _NewPollSheetState();
}

class _NewPollSheetState extends State<NewPollSheet> {
  final _question = TextEditingController();
  final _options = [TextEditingController(), TextEditingController()];
  final _focus = [FocusNode(), FocusNode()];
  bool _multi = false;

  @override
  void initState() {
    super.initState();
    _question.addListener(_changed);
    for (final c in _options) {
      c.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _question.dispose();
    for (final c in _options) {
      c.dispose();
    }
    for (final f in _focus) {
      f.dispose();
    }
    super.dispose();
  }

  void _changed() => setState(() {});

  PollBody? get _poll => validPoll(_question.text, [for (final c in _options) c.text], multi: _multi, replyTo: widget.replyTo);

  void _add() {
    if (_options.length >= maxPollOptions) return;
    final focus = FocusNode();
    setState(() {
      _options.add(TextEditingController()..addListener(_changed));
      _focus.add(focus);
    });
    focus.requestFocus();
  }

  void _remove(int i) {
    final c = _options.removeAt(i), f = _focus.removeAt(i);
    setState(() {});
    // After this frame: the field may still be using them.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      c.dispose();
      f.dispose();
    });
  }

  /// Why Send is off, when it isn't obvious: two options alike.
  String? get _problem {
    final seen = <String>{};
    for (final c in _options) {
      final t = c.text.trim().toLowerCase();
      if (t.isNotEmpty && !seen.add(t)) return 'Two options are the same.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final poll = _poll;
    final problem = _problem;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.xl, Space.lg, Space.lg, Space.sm),
            child: Row(children: [
              Expanded(child: Text('New poll', style: theme.textTheme.titleMedium)),
              FilledButton(
                key: const Key('poll-send'),
                onPressed: poll == null ? null : () => Navigator.pop(context, poll),
                child: const Text('Send'),
              ),
            ]),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: Space.xl),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TextField(
                  key: const Key('poll-question'),
                  controller: _question,
                  autofocus: true,
                  minLines: 1,
                  maxLines: 3,
                  textCapitalization: TextCapitalization.sentences,
                  inputFormatters: [LengthLimitingTextInputFormatter(maxPollQuestion)],
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => _focus.first.requestFocus(),
                  decoration: const InputDecoration(labelText: 'Question', hintText: 'Ask something'),
                ),
                const SizedBox(height: Space.md),
                Text('Options', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                for (var i = 0; i < _options.length; i++)
                  Padding(
                    key: ObjectKey(_options[i]),
                    padding: const EdgeInsets.only(top: Space.sm),
                    child: TextField(
                      key: Key('poll-option-field-$i'),
                      controller: _options[i],
                      focusNode: _focus[i],
                      textCapitalization: TextCapitalization.sentences,
                      inputFormatters: [LengthLimitingTextInputFormatter(maxPollOption)],
                      textInputAction: i == _options.length - 1 ? TextInputAction.done : TextInputAction.next,
                      onSubmitted: (_) {
                        if (i < _options.length - 1) _focus[i + 1].requestFocus();
                      },
                      decoration: InputDecoration(
                        hintText: 'Option ${i + 1}',
                        isDense: true,
                        suffixIcon: _options.length > 2
                            ? IconButton(
                                key: Key('poll-remove-$i'),
                                tooltip: 'Remove option',
                                icon: const Icon(Icons.close_rounded, size: 18),
                                onPressed: () => _remove(i),
                              )
                            : null,
                      ),
                    ),
                  ),
                if (problem != null)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.xs),
                    child: Text(problem, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
                  ),
                if (_options.length < maxPollOptions)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('poll-add-option'),
                      onPressed: _add,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add an option'),
                    ),
                  ),
                SwitchListTile(
                  key: const Key('poll-multi'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Allow more than one answer'),
                  subtitle: const Text('Off means everyone picks one'),
                  value: _multi,
                  onChanged: (v) => setState(() => _multi = v),
                ),
                const SizedBox(height: Space.md),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
