import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vardn/data/database.dart';
import 'package:vardn/services/event_log/device_id.dart';
import 'package:vardn/services/sync/event_applier.dart';

void main() {
  late AppDatabase db;
  late EventApplier applier;
  var eventCounter = 0;

  Map<String, Object?> event(
    String type,
    String entityId,
    String createdAt,
    Map<String, Object?> payload, {
    String deviceId = 'remote-device',
  }) =>
      {
        'id': 'evt-${eventCounter++}',
        'type': type,
        'deviceId': deviceId,
        'createdAt': createdAt,
        'entityId': entityId,
        'payload': payload,
      };

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    applier = EventApplier(db: db, deviceId: DeviceId.forTesting('local-device'));
  });

  tearDown(() => db.close());

  test('creates and patches a note with LWW', () async {
    await applier.applyOne(event('note.created', 'n1',
        '2026-08-18T10:00:00.000Z', {'title': 'Groceries'}));
    await applier.applyOne(event('note.updated', 'n1',
        '2026-08-18T10:05:00.000Z', {'title': 'Groceries!', 'pinned': true}));
    // An older, conflicting edit must lose.
    await applier.applyOne(event('note.updated', 'n1',
        '2026-08-18T10:01:00.000Z', {'title': 'stale'}));

    final note = await (db.select(db.notes)..where((t) => t.id.equals('n1')))
        .getSingle();
    expect(note.title, 'Groceries!');
    expect(note.pinned, true);
  });

  test('creates and patches blocks; partial patch keeps other fields',
      () async {
    await applier.applyOne(event('note.block.created', 'b1',
        '2026-08-18T10:00:00.000Z', {
      'noteId': 'n1',
      'type': 'checklist',
      'content': 'milk',
      'checked': false,
      'position': 1,
    }));
    await applier.applyOne(event('note.block.updated', 'b1',
        '2026-08-18T10:01:00.000Z', {'checked': true}));

    final block = await (db.select(db.noteBlocks)
          ..where((t) => t.id.equals('b1')))
        .getSingle();
    expect(block.content, 'milk');
    expect(block.checked, true);
    expect(block.type, 'checklist');
  });

  test('block delete arriving before create leaves the block deleted',
      () async {
    await applier.applyOne(
        event('note.block.deleted', 'b1', '2026-08-18T10:02:00.000Z', {}));
    await applier.applyOne(event('note.block.created', 'b1',
        '2026-08-18T10:00:00.000Z', {'noteId': 'n1', 'content': 'ghost'}));

    final block = await (db.select(db.noteBlocks)
          ..where((t) => t.id.equals('b1')))
        .getSingle();
    expect(block.deletedAt, isNotNull);
  });

  test('own events are recorded but not re-applied', () async {
    final applied = await applier.applyOne(event(
        'note.created', 'n1', '2026-08-18T10:00:00.000Z', {'title': 'mine'},
        deviceId: 'local-device'));
    expect(applied, false);
    final note = await (db.select(db.notes)..where((t) => t.id.equals('n1')))
        .getSingleOrNull();
    expect(note, isNull);
  });

  test('duplicate events are idempotent', () async {
    final e = event(
        'note.created', 'n1', '2026-08-18T10:00:00.000Z', {'title': 'once'});
    expect(await applier.applyOne(e), true);
    expect(await applier.applyOne(e), false);
  });
}
