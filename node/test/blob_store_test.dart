import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vardn_node/blob_store.dart';

void main() {
  late Directory tmp;
  late NodeBlobStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vardn_blob_test');
    store = NodeBlobStore(Directory('${tmp.path}/blobs'));
  });

  tearDown(() => tmp.delete(recursive: true));

  test('stores and reads back a verified blob', () async {
    final bytes = Uint8List.fromList(List.generate(1000, (i) => i % 256));
    final hash = NodeBlobStore.hashOf(bytes);
    expect(await store.putVerified(hash, bytes), true);
    expect(await store.exists(hash), true);
    expect(await store.read(hash), bytes);
    // Idempotent.
    expect(await store.putVerified(hash, bytes), true);
    expect(await store.count(), 1);
  });

  test('rejects bytes that do not match the claimed hash', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final wrongHash = NodeBlobStore.hashOf(Uint8List.fromList([9, 9, 9]));
    expect(await store.putVerified(wrongHash, bytes), false);
    expect(await store.exists(wrongHash), false);
  });

  test('rejects malformed hashes (no path traversal)', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    expect(await store.putVerified('../../etc/passwd', bytes), false);
    expect(await store.read('../identity.json'), isNull);
    expect(await store.exists('ABCD'), false);
  });
}
