import 'package:go_router/go_router.dart';

import 'screens/home_screen.dart';
import 'screens/spikes_screen.dart';

final appRouter = GoRouter(
  routes: [
    GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
    GoRoute(path: '/spikes', builder: (context, state) => const SpikesScreen()),
  ],
);
