import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

/// Long-term X25519 identity for a headless node, stored as a JSON file in
/// the data directory (a server has no OS keychain; protect the data dir with
/// filesystem permissions instead).
///
/// The id derivation matches the app's DeviceIdentity: base64url-encoded
/// SHA-256 of the public key, truncated to 16 bytes.
class NodeIdentity {
  NodeIdentity._({
    required this.id,
    required this.publicKeyBase64,
    required this.displayName,
  });

  final String id;
  final String publicKeyBase64;
  final String displayName;

  /// Short, human-friendly fingerprint (groups of 4 hex chars) — same format
  /// the app shows, so both sides can be compared by eye.
  String get shortFingerprint {
    final raw = base64Url.decode(id);
    final hex = raw
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    return [
      for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4),
    ].join('-');
  }

  static Future<NodeIdentity> load(Directory dataDir,
      {String? displayName}) async {
    final file = File(p.join(dataDir.path, 'identity.json'));
    final x25519 = X25519();

    String privB64;
    String pubB64;
    String name;
    if (await file.exists()) {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      privB64 = json['privateKey'] as String;
      pubB64 = json['publicKey'] as String;
      name = displayName ?? (json['displayName'] as String? ?? 'vardn-node');
    } else {
      final pair = await x25519.newKeyPair();
      final pub = await pair.extractPublicKey();
      privB64 = base64Url.encode(await pair.extractPrivateKeyBytes());
      pubB64 = base64Url.encode(pub.bytes);
      name = displayName ?? Platform.localHostname;
      if (name.isEmpty) name = 'vardn-node';
    }
    // Persist (also updates displayName when overridden via --name).
    await dataDir.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'privateKey': privB64,
      'publicKey': pubB64,
      'displayName': name,
    }));

    final hash = await Sha256().hash(base64Url.decode(pubB64));
    final id = base64Url.encode(hash.bytes.take(16).toList());
    return NodeIdentity._(id: id, publicKeyBase64: pubB64, displayName: name);
  }
}
