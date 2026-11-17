// Listens for shares from other apps and opens the Send to screen once signed in.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../router.dart';
import '../session/session_controller.dart';
import 'share.dart';

class ShareInbox extends ConsumerStatefulWidget {
  const ShareInbox({super.key});

  @override
  ConsumerState<ShareInbox> createState() => _ShareInboxState();
}

class _ShareInboxState extends ConsumerState<ShareInbox> {
  StreamSubscription<IncomingShare>? _sub;

  @override
  void initState() {
    super.initState();
    final source = ref.read(shareSourceProvider);
    _sub = source.updates.listen(_got);
    unawaited(source.initial().then(_got));
  }

  void _got(IncomingShare? share) {
    if (!mounted || share == null || share.isEmpty) return;
    ref.read(pendingShareProvider.notifier).set(share);
    _open();
  }

  void _open() {
    if (ref.read(sessionProvider) is! SignedIn || ref.read(pendingShareProvider) == null) return;
    ref.read(routerProvider).go('/share');
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A share that came before sign-in opens once signed in.
    ref.listen(sessionProvider, (prev, next) {
      if (prev is! SignedIn && next is SignedIn) WidgetsBinding.instance.addPostFrameCallback((_) => _open());
    });
    return const SizedBox.shrink();
  }
}
