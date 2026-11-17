import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../screens/account_providers.dart';
import 'klipy.dart';

/// GIF search, or null while the server hands out no KLIPY key (then there's no GIF button).
final gifClientProvider = FutureProvider.autoDispose<KlipyClient?>((ref) async {
  final me = await ref.watch(meProvider.future);
  final key = me.gifKey;
  if (key == null) return null;
  return KlipyClient(appKey: key, customerId: await klipyCustomerId(me.userId));
});
