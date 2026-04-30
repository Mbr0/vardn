import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Long-term X25519 identity for this install. Public key is shared during
/// pairing; private key never leaves secure storage. The device id is the
/// base64url-encoded SHA-256 of the public key (truncated to 16 bytes) — short
/// enough for display, long enough to make collisions infeasible.
class DeviceIdentity {
  DeviceIdentity._({
    required this.id,
    required this.keyPair,
    required this.publicKey,
    required this.displayName,
  });

  final String id;
  final SimpleKeyPair keyPair;
  final SimplePublicKey publicKey;
  final String displayName;

  static DeviceIdentity? _cached;
  static final _x25519 = X25519();
  static const _privateKeyKey = 'identity.x25519.privateKey';
  static const _publicKeyKey = 'identity.x25519.publicKey';
  static const _displayNameKey = 'identity.displayName';

  static final _storage = FlutterSecureStorage(
    iOptions: const IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    mOptions: const MacOsOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  String get publicKeyBase64 => base64Url.encode(publicKey.bytes);

  /// Short, human-friendly fingerprint (groups of 4 hex chars).
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

  static Future<DeviceIdentity> load() async {
    if (_cached != null) return _cached!;

    final storedPriv = await _storage.read(key: _privateKeyKey);
    final storedPub = await _storage.read(key: _publicKeyKey);
    final storedName = await _storage.read(key: _displayNameKey) ?? _defaultName();

    SimpleKeyPair pair;
    SimplePublicKey pub;
    if (storedPriv != null && storedPub != null) {
      final pubBytes = base64Url.decode(storedPub);
      final privBytes = base64Url.decode(storedPriv);
      pair = await _x25519.newKeyPairFromSeed(privBytes);
      pub = SimplePublicKey(pubBytes, type: KeyPairType.x25519);
    } else {
      pair = await _x25519.newKeyPair();
      pub = await pair.extractPublicKey();
      final priv = await pair.extractPrivateKeyBytes();
      await _storage.write(key: _privateKeyKey, value: base64Url.encode(priv));
      await _storage.write(key: _publicKeyKey, value: base64Url.encode(pub.bytes));
      await _storage.write(key: _displayNameKey, value: storedName);
    }

    final id = await _idForPublicKey(pub);
    return _cached = DeviceIdentity._(
      id: id,
      keyPair: pair,
      publicKey: pub,
      displayName: storedName,
    );
  }

  static Future<String> _idForPublicKey(SimplePublicKey pub) async {
    final hash = await Sha256().hash(pub.bytes);
    return base64Url.encode(hash.bytes.take(16).toList());
  }

  /// Mirror the id into a plain file so non-secure code (event_log) can read
  /// it without needing flutter_secure_storage.
  Future<void> mirrorIdToSupportDir() async {
    final support = await getApplicationSupportDirectory();
    final f = File(p.join(support.path, 'device_id'));
    await f.writeAsString(id);
  }

  Future<void> setDisplayName(String name) async {
    await _storage.write(key: _displayNameKey, value: name);
    _cached = DeviceIdentity._(
      id: id,
      keyPair: keyPair,
      publicKey: publicKey,
      displayName: name,
    );
  }

  static String _defaultName() {
    final host = Platform.localHostname;
    return host.isEmpty ? 'device' : host;
  }
}
