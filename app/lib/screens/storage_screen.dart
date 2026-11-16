// Admin: how much of the family's media storage is used.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../media/providers.dart';

/// "8.0 GB", "340 MB", "12 KB" (binary units, as the server counts).
String formatBytes(int b) {
  const k = 1024;
  if (b >= k * k * k) return '${(b / (k * k * k)).toStringAsFixed(1)} GB';
  if (b >= k * k) return '${(b / (k * k)).toStringAsFixed(b >= 100 * k * k ? 0 : 1)} MB';
  if (b >= k) return '${(b / k).round()} KB';
  return '$b B';
}

class StorageScreen extends ConsumerWidget {
  const StorageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(mediaUsageProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go('/')),
        title: const Text('Media storage'),
        actions: [
          IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(mediaUsageProvider)),
        ],
      ),
      body: switch (usage) {
        AsyncData(value: final u) => ListView(padding: const EdgeInsets.all(24), children: [
            Text('${formatBytes(u.usedBytes)} of ${formatBytes(u.capBytes)} used', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              key: const Key('storage-meter'),
              value: u.capBytes == 0 ? 0 : (u.usedBytes / u.capBytes).clamp(0.0, 1.0),
              minHeight: 10,
              borderRadius: BorderRadius.circular(5),
            ),
            const SizedBox(height: 12),
            Text('${u.files} ${u.files == 1 ? 'file' : 'files'} stored'
                '${u.expiredFiles > 0 ? ' · ${u.expiredFiles} expired' : ''}'),
            const SizedBox(height: 24),
            Text(
              'Photos and voice messages are stored encrypted; the server can’t see them. When storage '
              'passes ${formatBytes(u.capBytes)}, the oldest are removed until it’s under '
              '${formatBytes(u.evictToBytes)}, and their messages show “expired”.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ]),
        AsyncError() => Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text("Couldn't load storage usage."),
              TextButton(onPressed: () => ref.invalidate(mediaUsageProvider), child: const Text('Retry')),
            ]),
          ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}
