import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'screens/devices_screen.dart';
import 'screens/chats/chats_shell.dart';
import 'screens/chats/group_info_screen.dart';
import 'screens/chats/new_chat_screen.dart';
import 'screens/invite_screen.dart';
import 'screens/join_screen.dart';
import 'screens/loading_screen.dart';
import 'screens/spikes_screen.dart';
import 'session/session_controller.dart';

/// Where [location] must go for session state [s], or null to stay.
String? sessionRedirect(SessionState s, String location) {
  switch (s) {
    case SessionLoading() || SessionUnavailable():
      return location == '/loading' ? null : '/loading';
    case SignedOut():
      return location == '/join' || location == '/spikes' ? null : '/join';
    case SignedIn(:final session):
      if (location == '/join' || location == '/loading') return '/';
      if (location == '/invite' && !session.isAdmin) return '/';
      return null;
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final changes = ValueNotifier<SessionState>(ref.read(sessionProvider));
  ref.listen(sessionProvider, (_, next) => changes.value = next);
  final router = GoRouter(
    refreshListenable: changes,
    redirect: (context, state) => sessionRedirect(ref.read(sessionProvider), state.uri.path),
    routes: [
      GoRoute(path: '/loading', builder: (context, state) => const LoadingScreen()),
      GoRoute(path: '/join', builder: (context, state) => const JoinScreen()),
      GoRoute(path: '/', builder: (context, state) => const ChatsShell()),
      GoRoute(
        path: '/chats/:id',
        builder: (context, state) => ChatsShell(chatId: state.pathParameters['id']),
      ),
      GoRoute(
        path: '/chats/:id/info',
        builder: (context, state) => GroupInfoScreen(chatId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/chats/:id/add',
        builder: (context, state) => NewChatScreen(addTo: state.pathParameters['id']),
      ),
      GoRoute(
        path: '/new',
        builder: (context, state) => NewChatScreen(
          preselected: [...?state.uri.queryParameters['with']?.split(',').where((s) => s.isNotEmpty)],
        ),
      ),
      GoRoute(path: '/devices', builder: (context, state) => const DevicesScreen()),
      GoRoute(path: '/invite', builder: (context, state) => const InviteScreen()),
      GoRoute(path: '/spikes', builder: (context, state) => const SpikesScreen()),
    ],
  );
  ref.onDispose(() {
    router.dispose();
    changes.dispose();
  });
  return router;
});
