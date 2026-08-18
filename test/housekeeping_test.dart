import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vardn/services/blobs/blob_store.dart';
import 'package:vardn/services/event_log/device_id.dart';
import 'package:vardn/services/event_log/event.dart';
import 'package:vardn/services/event_log/event_writer.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vardn_housekeeping');
  });

  tearDown(() => tmp.delete(recursive: true));

  group('EventWriter.pruneBefore', () {
    late EventWriter writer;

    setUp(() {
      writer = EventWriter(
        deviceId: DeviceId.forTesting('dev'),
        directory: tmp,
      );
    });

    MutationEvent eventAt(String id, DateTime at) => MutationEvent(
          id: id,
          type: EventType.todoCreated,
          deviceId: 'dev',
          createdAt: at,
          entityId: 'e-$id',
          payload: const {},
        );

    test('removes only events strictly before the cutoff', () async {
      final t0 = DateTime.utc(2026, 1, 1);
      final t1 = DateTime.utc(2026, 2, 1);
      final t2 = DateTime.utc(2026, 3, 1);
      await writer.append(eventAt('a', t0));
      await writer.append(eventAt('b', t1));
      await writer.append(eventAt('c', t2));

      final removed = await writer.pruneBefore(t1.millisecondsSinceEpoch);
      expect(removed, 1);
      final remaining = await writer.readSince(0);
      expect(remaining.map((e) => e['id']), ['b', 'c']);
    });
  });

  group('BlobStore.deleteUnreferenced', () {
    late BlobStore store;

    setUp(() {
      store = BlobStore(directory: tmp);
    });

    Future<String> putAged(List<int> bytes, {required bool old}) async {
      final hash = await store.put(Uint8List.fromList(bytes));
      if (old) {
        final past = DateTime.now().subtract(const Duration(days: 2));
        await store.fileFor(hash).setLastModified(past);
      }
      return hash;
    }

    test('keeps referenced and fresh blobs, deletes old orphans', () async {
      final kept = await putAged([1, 1, 1], old: true);
      final orphanOld = await putAged([2, 2, 2], old: true);
      final orphanFresh = await putAged([3, 3, 3], old: false);

      final freed = await store.deleteUnreferenced({kept});
      expect(freed, 3); // only the old orphan's 3 bytes
      expect(await store.exists(kept), true);
      expect(await store.exists(orphanOld), false);
      expect(await store.exists(orphanFresh), true); // within grace period
    });

    test('removes stray temp files but never non-hash names', () async {
      final past = DateTime.now().subtract(const Duration(days: 2));
      final stray = File('${tmp.path}/deadbeef.tmp');
      await stray.writeAsBytes([1, 2, 3]);
      await stray.setLastModified(past);
      final other = File('${tmp.path}/README');
      await other.writeAsBytes([9]);
      await other.setLastModified(past);

      await store.deleteUnreferenced({});
      expect(await stray.exists(), false);
      expect(await other.exists(), true);
    });
  });
}
