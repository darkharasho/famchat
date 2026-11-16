import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:famchat/spikes/db_spike.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('insert and read', () async {
    final db = SpikeDb(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.notes).insert(NotesCompanion.insert(body: 'one'));
    await db.into(db.notes).insert(NotesCompanion.insert(body: 'two'));
    final rows = await (db.select(db.notes)..orderBy([(n) => OrderingTerm(expression: n.id)])).get();
    expect(rows.map((r) => r.body), ['one', 'two']);
  });
}
