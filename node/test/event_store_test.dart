import 'dart:io';

import 'package:test/test.dart';
import 'package:vardn_node/event_store.dart';

void main() {
  late Directory tmp;
  late RelayEventStore store;

  Map<String, Object?> event(String id, String deviceId, String createdAt) => {
        'id': id,
        'type': 'todo.created',
        'deviceId': deviceId,
        'createdAt': createdAt,
        'entityId': 'entity-$id',
        'payload': {'title': id},
      };

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vardn_node_test');
    store = RelayEventStore(Directory('${tmp.path}/events'));
  });

  tearDown(() => tmp.delete(recursive: true));

  test('stores events and reads them back merged and ordered', () async {
    await store.put([
      event('b', 'devB', '2026-08-18T10:00:02.000Z'),
      event('a', 'devA', '2026-08-18T10:00:01.000Z'),
    ]);
    final all = await store.readSince(0);
    expect(all.map((e) => e['id']), ['a', 'b']);
    expect(await store.latestTimestampMs(),
        DateTime.parse('2026-08-18T10:00:02.000Z').millisecondsSinceEpoch);
  });

  test('since filter is strict and matches the app watermark semantics',
      () async {
    await store.put([event('a', 'devA', '2026-08-18T10:00:01.000Z')]);
    final ts = DateTime.parse('2026-08-18T10:00:01.000Z').millisecondsSinceEpoch;
    expect(await store.readSince(ts), isEmpty);
    expect(await store.readSince(ts - 1), hasLength(1));
  });

  test('re-posting the same event is idempotent', () async {
    final e = event('a', 'devA', '2026-08-18T10:00:01.000Z');
    await store.put([e]);
    await store.put([e]);
    expect(await store.readSince(0), hasLength(1));
  });

  test('rejects events with path-unsafe or missing fields', () async {
    expect(
      await store.put([
        event('../../evil', 'devA', '2026-08-18T10:00:01.000Z'),
        event('ok', 'dev/../A', '2026-08-18T10:00:01.000Z'),
        {'id': 'x', 'type': 'todo.created'}, // missing fields
        event('ok2', 'devA', 'not-a-date'),
      ]),
      0,
    );
    expect(await store.readSince(0), isEmpty);
  });
}
