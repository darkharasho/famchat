// Invite links opened on a phone (docs/superpowers/specs/2026-11-17-app-links-design.md): iOS
// Universal Links and Android App Links bring https://famchat.dev/join#<token> to the installed
// app, which opens Join with the invite filled in.
import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../push/providers.dart' show rootMessengerKeyProvider;
import '../router.dart';
import 'invite_link.dart';
import 'session_controller.dart';

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

/// The invite in [uri] when it's a famchat.dev invite link, else null.
String? inviteFromLink(Uri uri) {
  if (uri.scheme != 'https' || uri.host != 'famchat.dev') return null;
  return inviteTokenFromUri(uri);
}

/// Opens Join for invite links (or says you're already signed in).
class InviteLinkListener extends ConsumerStatefulWidget {
  const InviteLinkListener({super.key});

  @override
  ConsumerState<InviteLinkListener> createState() => _InviteLinkListenerState();
}

class _InviteLinkListenerState extends ConsumerState<InviteLinkListener> {
  StreamSubscription<Uri>? _sub;

  @override
  void initState() {
    super.initState();
    final links = ref.read(incomingLinksProvider);
    _sub = links.links.listen(_open);
    unawaited(links.initial().then((u) {
      if (u != null) _open(u);
    }));
  }

  void _open(Uri uri) {
    if (!mounted) return;
    final invite = inviteFromLink(uri);
    if (invite == null) return;
    if (ref.read(sessionProvider) is SignedIn) {
      ref.read(rootMessengerKeyProvider).currentState?.showSnackBar(const SnackBar(content: Text("You're already signed in.")));
      return;
    }
    ref.read(pendingInviteProvider.notifier).set(invite);
    ref.read(routerProvider).go('/join');
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
