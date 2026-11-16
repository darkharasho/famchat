import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../session/session_controller.dart';

// The API client already retries refreshes; Riverpod's own retry would repeat failed calls.
Duration? _noRetry(int count, Object error) => null;

/// `GET /api/me`; also keeps the stored name and admin flag current.
final meProvider = FutureProvider.autoDispose<Me>((ref) async {
  final me = await ref.watch(apiClientProvider).me();
  await ref.read(sessionProvider.notifier).updateProfile(me);
  return me;
}, retry: _noRetry);

final devicesProvider = FutureProvider.autoDispose<List<DeviceInfo>>(
  (ref) => ref.watch(apiClientProvider).listDevices(),
  retry: _noRetry,
);
