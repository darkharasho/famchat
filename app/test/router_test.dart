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
      (SessionUnavailable('x'), '/devices', '/loading'),
      (out, '/', '/join'),
      (out, '/devices', '/join'),
      (out, '/loading', '/join'),
      (out, '/join', null),
      (out, '/spikes', null),
      (out, '/pair', null),
      (out, '/devices/add', '/join'),
    ];
    for (final (s, loc, want) in cases) {
      expect(sessionRedirect(s, loc), want, reason: '$s $loc');
    }
    expect(sessionRedirect(user, '/join'), '/');
    expect(sessionRedirect(user, '/loading'), '/');
    expect(sessionRedirect(user, '/pair'), '/');
    expect(sessionRedirect(user, '/devices/add'), isNull);
    expect(sessionRedirect(user, '/'), isNull);
    expect(sessionRedirect(user, '/devices'), isNull);
    expect(sessionRedirect(user, '/spikes'), isNull);
    expect(sessionRedirect(user, '/invite'), '/');
    expect(sessionRedirect(admin, '/invite'), isNull);
  });
}
