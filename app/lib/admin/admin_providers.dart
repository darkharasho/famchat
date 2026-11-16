// Riverpod wiring for the admin screens.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../chat/providers.dart';
import '../chat/wire.dart';
import '../session/session_controller.dart';
import 'admin_service.dart';

/// The admin actions for this device's user, or null when signed out.
final adminServiceProvider = Provider<AdminService?>((ref) {
  final s = ref.watch(sessionProvider);
  if (s is! SignedIn) return null;
  return AdminService(
    api: ref.watch(apiClientProvider),
    userId: s.session.userId,
    identity: s.session.identityKey,
    now: ref.watch(clockProvider),
  );
});

Duration? _noRetry(int count, Object error) => null;

/// The reviewer invite and reviewer accounts (`GET /admin/reviewers`), for the Family screen.
final reviewersProvider = FutureProvider.autoDispose<Reviewers>(
  (ref) => ref.watch(apiClientProvider).reviewers(),
  retry: _noRetry,
);

/// The family as the server lists it now (`GET /users`), for the Family screen.
final familyProvider = FutureProvider.autoDispose<List<UserDto>>(
  (ref) => ref.watch(chatApiProvider).users(),
  retry: _noRetry,
);
