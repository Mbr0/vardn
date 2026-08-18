import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Content-addressed store for binary attachments (images). Files live at
/// `app_support/blobs/<sha256-hex>`; an image block's `content` column holds
/// the hash, and the bytes travel between peers via the /blobs sync routes.
///
/// Content addressing makes replication trivial: a hash either exists or it
/// doesn't, transfers are idempotent, and integrity is verified for free.
class BlobStore {
  BlobStore({required this.directory});

  final Directory directory;

  static final _hashPattern = RegExp(r'^[a-f0-9]{64}$');

  static bool looksLikeHash(String s) => _hashPattern.hasMatch(s);

  static String hashOf(List<int> bytes) => sha256.convert(bytes).toString();

  static Future<BlobStore> create() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'blobs'));
    await dir.create(recursive: true);
    return BlobStore(directory: dir);
  }

  File fileFor(String hash) => File(p.join(directory.path, hash));

  Future<bool> exists(String hash) =>
      looksLikeHash(hash) ? fileFor(hash).exists() : Future.value(false);

  /// Stores [bytes] and returns their hash. Idempotent.
  Future<String> put(Uint8List bytes) async {
    final hash = hashOf(bytes);
    final file = fileFor(hash);
    if (!await file.exists()) {
      // Write via a temp file so a crash never leaves a corrupt blob under
      // its final name.
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
    }
    return hash;
  }

  /// Stores [bytes] only if they match [expectedHash] (used when receiving
  /// from a peer). Returns true when stored or already present.
  Future<bool> putVerified(String expectedHash, Uint8List bytes) async {
    if (!looksLikeHash(expectedHash)) return false;
    if (hashOf(bytes) != expectedHash) return false;
    await put(bytes);
    return true;
  }

  Future<Uint8List?> read(String hash) async {
    if (!looksLikeHash(hash)) return null;
    final file = fileFor(hash);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  /// Deletes blobs whose hash is not in [referenced], plus stray temp files.
  /// Files newer than [minAge] are kept — a blob may be written moments
  /// before the block event referencing it lands. Returns bytes freed.
  Future<int> deleteUnreferenced(
    Set<String> referenced, {
    Duration minAge = const Duration(days: 1),
  }) async {
    if (!await directory.exists()) return 0;
    final threshold = DateTime.now().subtract(minAge);
    var freed = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      final isStrayTmp = name.endsWith('.tmp');
      if (!isStrayTmp && (!looksLikeHash(name) || referenced.contains(name))) {
        continue;
      }
      try {
        final stat = await entity.stat();
        if (stat.modified.isAfter(threshold)) continue;
        freed += stat.size;
        await entity.delete();
      } catch (_) {/* keep going */}
    }
    return freed;
  }
}
