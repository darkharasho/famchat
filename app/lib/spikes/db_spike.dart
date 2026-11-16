import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'db_spike.g.dart';

class Notes extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get body => text()();
}

@DriftDatabase(tables: [Notes])
class SpikeDb extends _$SpikeDb {
  SpikeDb(super.e);

  @override
  int get schemaVersion => 1;
}

SpikeDb openSpikeDb(String name) => SpikeDb(
      driftDatabase(
        name: name,
        web: DriftWebOptions(
          sqlite3Wasm: Uri.parse('sqlite3.wasm'),
          driftWorker: Uri.parse('drift_worker.js'),
        ),
      ),
    );

/// Inserts `"hello <timestamp>"`, closes the database, reopens it and returns that row's body.
/// Throws if the row is gone after reopening.
Future<String> dbRoundTrip(String name) async {
  final body = 'hello ${DateTime.now().millisecondsSinceEpoch}';
  final first = openSpikeDb(name);
  final id = await first.into(first.notes).insert(NotesCompanion.insert(body: body));
  await first.close();

  final second = openSpikeDb(name);
  try {
    final row = await (second.select(second.notes)..where((n) => n.id.equals(id))).getSingleOrNull();
    if (row == null) throw StateError('row $id missing after reopen');
    return row.body;
  } finally {
    await second.close();
  }
}
