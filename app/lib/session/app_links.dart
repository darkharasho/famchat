// Invite links opened on a phone (docs/superpowers/specs/2026-11-17-app-links-design.md): iOS
// Universal Links and Android App Links bring https://famchat.dev/join#<token> to the installed
// app, which opens Join with the invite filled in.
import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../push/providers.dart' show rootMessengerKeyProvider;
import '../api/models.dart';
import '../chat/providers.dart' show familiesProvider;
import '../router.dart';
import '../screens/account_providers.dart' show meProvider;
import '../screens/join_family_sheet.dart';
import 'invite_link.dart';
import 'session_controller.dart';

export 'invite_link.dart' show inviteFromLink;

/// Links the system hands the app.
abstract interface class IncomingLinks {
  /// The link that launched the app, if any.
  Future<Uri?> initial();

  /// Links that arrive while it runs.
  Stream<Uri> get links;
}

class _PlatformLinks implements IncomingLinks {
  final _plugin = AppLinks();

  @override
  Future<Uri?> initial() async {
    try {
      return await _plugin.getInitialLink();
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<Uri> get links => _plugin.uriLinkStream.handleError((Object _) {});
}

/// No links (desktop, web; tests).
class NoIncomingLinks implements IncomingLinks {
  const NoIncomingLinks();
  @override
  Future<Uri?> initial() async => null;
  @override
  Stream<Uri> get links => const Stream.empty();
}

/// The phone apps get links; the web reads its own address and desktops have none.
final incomingLinksProvider = Provider<IncomingLinks>((ref) =>
    !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)
        ? _PlatformLinks()
        : const NoIncomingLinks());

/// Opens Join for invite links; signed in, offers to join the family instead.
class InviteLinkListener extends ConsumerStatefulWidget {
  const InviteLinkListener({super.key});

  @override
  ConsumerState<InviteLinkListener> createState() => _InviteLinkListenerState();
}

class _InviteLinkListenerState extends ConsumerState<InviteLinkListener> {
  StreamSubscription<Uri>? _sub;
  StreamSubscription<Uri>? _tappedSub;

  @override
  void initState() {
    super.initState();
    final links = ref.read(incomingLinksProvider);
    _sub = links.links.listen(_open);
    _tappedSub = tappedInviteLinks.listen(_open);
    unawaited(links.initial().then((u) {
      if (u != null) _open(u);
    }));
  }

  void _open(Uri uri) {
    if (!mounted) return;
    final invite = inviteFromLink(uri);
    if (invite == null) return;
    if (ref.read(sessionProvider) is SignedIn) {
      unawaited(_offer(invite));
      return;
    }
    ref.read(pendingInviteProvider.notifier).set(invite);
    ref.read(routerProvider).go('/join');
  }

  /// Signed in: a family invite offers to join; a reviewer (link or account) just hears they're in.
  Future<void> _offer(String invite) async {
    final messenger = ref.read(rootMessengerKeyProvider);
    void alreadySignedIn() =>
        messenger.currentState?.showSnackBar(const SnackBar(content: Text("You're already signed in.")));
    if (isReviewerInvite(invite)) return alreadySignedIn();
    final me = await ref.read(meProvider.future).then<Me?>((m) => m, onError: (_) => null);
    if (!mounted) return;
    if (me == null || me.reviewer) return alreadySignedIn();
    await offerToJoinFamily(
      api: ref.read(apiClientProvider),
      onJoined: () {
        if (mounted) ref.invalidate(familiesProvider);
      },
      sheetContext: () => ref.read(routerProvider).routerDelegate.navigatorKey.currentContext!,
      messenger: messenger.currentState,
      token: splitInvite(invite).token,
    );
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(_tappedSub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
