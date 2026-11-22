import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart' show MaterialPage, MediaQuery;

import 'screens/chats/chat_media_screen.dart';
import 'screens/add_device_screen.dart';
import 'screens/devices_screen.dart';
import 'screens/families_screen.dart';
import 'screens/family_screen.dart';
import 'screens/recover_screen.dart';
import 'screens/recovery_code_screen.dart';
import 'screens/chats/chats_shell.dart';
import 'screens/chats/group_info_screen.dart';
import 'screens/chats/new_chat_screen.dart';
import 'screens/chats/search_screen.dart';
import 'screens/invite_screen.dart';
import 'screens/join_screen.dart';
import 'screens/loading_screen.dart';
import 'screens/pair_screen.dart';
import 'screens/operator_screen.dart';
import 'screens/settings_screen.dart';
import 'settings/appearance_screen.dart';
import 'screens/share_screen.dart';
import 'screens/spikes_screen.dart';
import 'screens/starred_screen.dart';
import 'screens/storage_screen.dart';
import 'session/session_controller.dart';

export 'push/chat_route.dart' show chatRoute;

/// A location the loading screen swallowed (a web deep link, a notification tap at launch), to go
/// to once the session is ready instead of home.
class PendingLocation {
  String? value;
}

final pendingLocationProvider = Provider<PendingLocation>((ref) => PendingLocation());

const _signInPages = {'/join', '/pair', '/recover', '/loading'};

/// Where [location] must go for session state [s], or null to stay. With [pending], a location
/// sent to the loading screen is remembered and returned to once signed in.
String? sessionRedirect(SessionState s, String location, {PendingLocation? pending}) {
  switch (s) {
    case SessionLoading() || SessionUnavailable():
      if (location == '/loading') return null;
      if (pending != null) pending.value = _signInPages.contains(location) || location == '/' ? null : location;
      return '/loading';
    case SignedOut():
      pending?.value = null;
      return location == '/join' || location == '/pair' || location == '/recover' || location == '/spikes' ? null : '/join';
    case SignedIn(:final session):
      if (_signInPages.contains(location)) {
        final back = pending?.value;
        pending?.value = null;
        if (back == null) return '/';
        return sessionRedirect(s, back) ?? back;
      }
      if ((location == '/settings/storage' || location == '/settings/family' ||
              location.startsWith('/settings/family/')) &&
          !session.isAdmin) {
        return '/';
      }
      return null;
  }
}

int _familyId(GoRouterState state) => int.tryParse(state.pathParameters['id']!) ?? 0;

final routerProvider = Provider<GoRouter>((ref) {
  final changes = ValueNotifier<SessionState>(ref.read(sessionProvider));
  final pending = ref.read(pendingLocationProvider);
  ref.listen(sessionProvider, (_, next) => changes.value = next);
  final router = GoRouter(
    refreshListenable: changes,
    redirect: (context, state) => sessionRedirect(ref.read(sessionProvider), state.uri.path, pending: pending),
    routes: [
      GoRoute(path: '/loading', builder: (context, state) => const LoadingScreen()),
      GoRoute(path: '/join', builder: (context, state) => const JoinScreen()),
      GoRoute(path: '/pair', builder: (context, state) => const PairScreen()),
      // Screens nest under where they're opened from, so the router keeps a real stack: back (the
      // button, a swipe on iOS, the gesture on Android) pops with the reverse animation.
      GoRoute(
        path: '/',
        builder: (context, state) => const ChatsShell(),
        routes: [
          GoRoute(
            path: 'chats/:id',
            pageBuilder: (context, state) {
              final child = ChatsShell(chatId: state.pathParameters['id'], jumpTo: state.uri.queryParameters['m']);
              // Side by side (wide windows), picking a chat swaps the pane in place, no slide.
              return MediaQuery.sizeOf(context).width >= ChatsShell.twoPaneWidth
                  ? NoTransitionPage(key: state.pageKey, child: child)
                  : MaterialPage(key: state.pageKey, child: child);
            },
            routes: [
              GoRoute(
                path: 'info',
                builder: (context, state) => GroupInfoScreen(chatId: state.pathParameters['id']!),
                routes: [
                  GoRoute(path: 'add', builder: (context, state) => NewChatScreen(addTo: state.pathParameters['id'])),
                ],
              ),
              GoRoute(path: 'media', builder: (context, state) => ChatMediaScreen(chatId: state.pathParameters['id']!)),
            ],
          ),
          GoRoute(
            path: 'new',
            builder: (context, state) => NewChatScreen(
              preselected: [...?state.uri.queryParameters['with']?.split(',').where((s) => s.isNotEmpty)],
            ),
          ),
          GoRoute(path: 'search', builder: (context, state) => SearchScreen(chatId: state.uri.queryParameters['chat'])),
          GoRoute(path: 'share', builder: (context, state) => const ShareScreen()),
          GoRoute(
            path: 'settings',
            builder: (context, state) => const SettingsScreen(),
            routes: [
              GoRoute(
                path: 'devices',
                builder: (context, state) => const DevicesScreen(),
                routes: [GoRoute(path: 'add', builder: (context, state) => const AddDeviceScreen())],
              ),
              GoRoute(path: 'storage', builder: (context, state) => const StorageScreen()),
              GoRoute(path: 'starred', builder: (context, state) => const StarredScreen()),
              GoRoute(path: 'appearance', builder: (context, state) => const AppearanceScreen()),
              GoRoute(
                path: 'families',
                builder: (context, state) => const FamiliesScreen(),
                routes: [
                  GoRoute(
                    path: ':id',
                    // An id that isn't a number is no family of mine: the screen says not found.
                    builder: (context, state) => FamilyScreen(familyId: _familyId(state)),
                    routes: [
                      GoRoute(path: 'invite', builder: (context, state) => InviteScreen(familyId: _familyId(state))),
                      GoRoute(
                        path: 'recovery-code',
                        builder: (context, state) => RecoveryCodeScreen(familyId: _familyId(state)),
                      ),
                    ],
                  ),
                ],
              ),
              GoRoute(path: 'operator', builder: (context, state) => const OperatorScreen()),
              // The one-family screen's old address (the admin setup banner, old links).
              GoRoute(path: 'family', redirect: (context, state) => '/settings/families/1'),
            ],
          ),
        ],
      ),
      GoRoute(path: '/spikes', builder: (context, state) => const SpikesScreen()),
      GoRoute(path: '/recover', builder: (context, state) => const RecoverScreen()),
    ],
  );
  ref.onDispose(() {
    router.dispose();
    changes.dispose();
  });
  return router;
});
