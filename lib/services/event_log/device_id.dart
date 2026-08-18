import 'dart:async';

import '../identity/device_identity.dart';

/// Thin wrapper exposing the stable device id derived from [DeviceIdentity].
/// The id is the base64url-encoded SHA-256 fingerprint (16 bytes) of the
/// device's long-term X25519 public key.
class DeviceId {
  DeviceId._(this.value);

  /// For tests only — production code must go through [load].
  DeviceId.forTesting(this.value);

  final String value;

  static DeviceId? _cached;

  static Future<DeviceId> load() async {
    if (_cached != null) return _cached!;
    final identity = await DeviceIdentity.load();
    await identity.mirrorIdToSupportDir();
    return _cached = DeviceId._(identity.id);
  }
}
