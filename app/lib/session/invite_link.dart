// Invite links look like https://famchat.dev/join#<token> (plan 1, POST /api/admin/invites).
// A reset link (plan 10) adds the one-time claim key seed: /join#<token>.<seed>. The seed stays in
// the fragment, so it never reaches the server; only the token is sent.
// A reviewer link (docs/protocol.md "Reviewer accounts") is marked: /join#review.<token>. The
// joiner then picks their own display name; the marker isn't sent either.
import 'dart:async';
import 'dart:typed_data';

import '../crypto/encoding.dart';

const _reviewerMarker = 'review.';

final _token = RegExp(r'^(review\.[A-Za-z0-9_-]{20,128}|[A-Za-z0-9_-]{20,128}(\.[A-Za-z0-9_-]{43})?)$');

/// The invite (token, `token.seed` for a reset link, `review.token` for a reviewer link) from a
/// pasted link, `#token`, or a bare token; null if there isn't one. Accepts any host, since the
/// token is only ever sent to our own API.
String? parseInviteToken(String input) {
  var s = input.trim();
  final hash = s.lastIndexOf('#');
  if (hash >= 0) s = s.substring(hash + 1).trim();
  return _token.hasMatch(s) ? s : null;
}

/// The invite when the app was opened at `/join#<token>` (web), else null.
String? inviteTokenFromUri(Uri uri) {
  if (!uri.path.endsWith('/join') || uri.fragment.isEmpty) return null;
  return parseInviteToken(uri.fragment);
}

/// The invite in [uri] when it's a famchat.dev invite link, else null.
String? inviteFromLink(Uri uri) {
  if (uri.scheme != 'https' || uri.host != 'famchat.dev') return null;
  return inviteTokenFromUri(uri);
}

final _tapped = StreamController<Uri>.broadcast();

/// Invite links tapped inside the app (in a message or its link preview), which
/// InviteLinkListener (session/app_links.dart) handles like ones the system brings.
Stream<Uri> get tappedInviteLinks => _tapped.stream;

/// Handles [uri] in the app when it's an invite link, and says whether it did. Opening one
/// through the system doesn't work on iOS: it never sends an app its own universal links, so
/// the link would open in Safari.
bool openInviteInApp(Uri uri) {
  if (inviteFromLink(uri) == null) return false;
  _tapped.add(uri);
  return true;
}

/// A parsed invite is a reviewer link: the joiner names themselves.
bool isReviewerInvite(String invite) => invite.startsWith(_reviewerMarker);

/// Splits a parsed invite into the token the server knows, for a reset link the claim key seed
/// (32 bytes) only the new device uses, and whether it is a reviewer link.
({String token, Uint8List? claimSeed, bool reviewer}) splitInvite(String invite) {
  if (isReviewerInvite(invite)) return (token: invite.substring(_reviewerMarker.length), claimSeed: null, reviewer: true);
  final dot = invite.indexOf('.');
  if (dot < 0) return (token: invite, claimSeed: null, reviewer: false);
  return (token: invite.substring(0, dot), claimSeed: b64urlDecode(invite.substring(dot + 1)), reviewer: false);
}
