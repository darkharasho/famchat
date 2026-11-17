import 'package:famchat/push/chat_route.dart';
import 'package:famchat/router.dart';
import 'package:famchat/session/session_controller.dart';
import 'package:famchat/session/stored_session.dart';
import 'package:flutter_test/flutter_test.dart';

StoredSession session({bool admin = false}) => StoredSession(
      userId: 'u',
      deviceId: 'd',
      deviceName: 'Pixel',
      refreshToken: 'r',
      isAdmin: admin,
      name: null,
      identitySeed: 'x',
      encSeed: 'x',
      signSeed: 'x',
    );

void main() {
  test('sessionRedirect', () {
    final user = SignedIn(session());
    final admin = SignedIn(session(admin: true));
    const out = SignedOut();
    const cases = <(SessionState, String, String?)>[
      (SessionLoading(), '/', '/loading'),
      (SessionLoading(), '/join', '/loading'),
      (SessionLoading(), '/loading', null),
      (SessionUnavailable('x'), '/settings/devices', '/loading'),
      (out, '/', '/join'),
      (out, '/settings/devices', '/join'),
      (out, '/loading', '/join'),
      (out, '/join', null),
      (out, '/spikes', null),
      (out, '/pair', null),
      (out, '/settings/devices/add', '/join'),
    ];
    for (final (s, loc, want) in cases) {
      expect(sessionRedirect(s, loc), want, reason: '$s $loc');
    }
    expect(sessionRedirect(user, '/join'), '/');
    expect(sessionRedirect(user, '/loading'), '/');
    expect(sessionRedirect(user, '/pair'), '/');
    expect(sessionRedirect(user, '/settings/devices/add'), isNull);
    expect(sessionRedirect(user, '/'), isNull);
    expect(sessionRedirect(user, '/settings/devices'), isNull);
    expect(sessionRedirect(user, '/spikes'), isNull);
    // Any family's admin invites from its own screen; the server checks the role.
    expect(sessionRedirect(user, '/settings/families/2/invite'), isNull);
    expect(sessionRedirect(user, '/settings/families/2/recovery-code'), isNull);
    expect(sessionRedirect(out, '/recover'), isNull);
    expect(sessionRedirect(user, '/recover'), '/');
    expect(sessionRedirect(user, '/settings/family'), '/');
    expect(sessionRedirect(user, '/settings/family/recovery-code'), '/');
    expect(sessionRedirect(admin, '/settings/family'), isNull);
    expect(sessionRedirect(admin, '/settings/family/recovery-code'), isNull);
  });

  test('a signed-in location swallowed by loading is restored after sign-in', () {
    final pending = PendingLocation();
    expect(sessionRedirect(const SessionLoading(), '/chats/01ARZ3NDEKTSV4RRFFQ69G5FAV', pending: pending), '/loading');
    expect(pending.value, '/chats/01ARZ3NDEKTSV4RRFFQ69G5FAV');
    // The loading screen itself doesn't overwrite it.
    expect(sessionRedirect(const SessionLoading(), '/loading', pending: pending), isNull);
    expect(sessionRedirect(SignedIn(session()), '/loading', pending: pending), '/chats/01ARZ3NDEKTSV4RRFFQ69G5FAV');
    expect(pending.value, isNull);
    expect(sessionRedirect(SignedIn(session()), '/loading', pending: pending), '/');
  });

  test('a pending location is dropped when signed out, and admin pages stay admin-only', () {
    final pending = PendingLocation();
    sessionRedirect(const SessionLoading(), '/chats/01ARZ3NDEKTSV4RRFFQ69G5FAV', pending: pending);
    expect(sessionRedirect(const SignedOut(), '/loading', pending: pending), '/join');
    expect(pending.value, isNull);
    sessionRedirect(const SessionLoading(), '/settings/storage', pending: pending);
    expect(sessionRedirect(SignedIn(session()), '/loading', pending: pending), '/');
    sessionRedirect(const SessionLoading(), '/settings/storage', pending: pending);
    expect(sessionRedirect(SignedIn(session(admin: true)), '/loading', pending: pending), '/settings/storage');
    // Sign-in pages are never remembered.
    sessionRedirect(const SessionLoading(), '/join', pending: pending);
    expect(pending.value, isNull);
    sessionRedirect(const SessionLoading(), '/chats/01ARZ3NDEKTSV4RRFFQ69G5FAV', pending: pending);
    sessionRedirect(const SessionLoading(), '/recover', pending: pending);
    expect(pending.value, isNull);
  });

  test('chatRoute accepts only chat ids', () {
    expect(chatRoute('01ARZ3NDEKTSV4RRFFQ69G5FAV'), '/chats/01ARZ3NDEKTSV4RRFFQ69G5FAV');
    expect(chatRoute(null), isNull);
    expect(chatRoute('../devices'), isNull);
    expect(chatRoute('01arz3ndektsv4rrffq69g5fav'), isNull);
    expect(isChatRoute('/chats/01ARZ3NDEKTSV4RRFFQ69G5FAV'), isTrue);
    for (final r in [null, '/settings/devices', '/chats/x', '/chats/01ARZ3NDEKTSV4RRFFQ69G5FAV/info']) {
      expect(isChatRoute(r), isFalse, reason: '$r');
    }
  });
}
