import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Content-addressed blob storage — same layout and semantics as the app's
/// BlobStore (`blobs/<sha256-hex>`), so the node can hold every attachment
/// even when the originating phone is offline.
class NodeBlobStore {
  NodeBlobStore(this.root);

  /// e.g. `<dataDir>/blobs`
  final Directory root;

  static final _hashPattern = RegExp(r'^[a-f0-9]{64}$');

  static bool looksLikeHash(String s) => _hashPattern.hasMatch(s);

  static String hashOf(List<int> bytes) => sha256.convert(bytes).toString();

  File fileFor(String hash) => File(p.join(root.path, hash));

  Future<bool> exists(String hash) =>
      looksLikeHash(hash) ? fileFor(hash).exists() : Future.value(false);

  /// Stores [bytes] only when they hash to [expectedHash]. Idempotent.
  /// Returns true when stored or already present.
  Future<bool> putVerified(String expectedHash, Uint8List bytes) async {
    if (!looksLikeHash(expectedHash)) return false;
    if (hashOf(bytes) != expectedHash) return false;
    final file = fileFor(expectedHash);
    if (!await file.exists()) {
      await root.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
    }
    return true;
  }

  Future<Uint8List?> read(String hash) async {
    if (!looksLikeHash(hash)) return null;
    final file = fileFor(hash);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  Future<int> count() async {
    if (!await root.exists()) return 0;
    var n = 0;
    await for (final e in root.list(followLinks: false)) {
      if (e is File && !e.path.endsWith('.tmp')) n++;
    }
    return n;
  }
}
