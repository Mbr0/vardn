import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:nsd/nsd.dart';

import '../identity/device_identity.dart';
import 'peer_endpoint.dart';

const _serviceType = '_vardn._tcp';

class DiscoveredPeer {
  DiscoveredPeer({
    required this.deviceId,
    required this.endpoint,
    required this.displayName,
    this.publicKey = '',
  });
  final String deviceId;
  final PeerEndpoint endpoint;
  final String displayName;
  final String publicKey; // base64url X25519, from the mDNS TXT record
}

/// Announces this device on the LAN via mDNS and watches for other instances.
class PeerDiscovery {
  PeerDiscovery({required this.identity});

  final DeviceIdentity identity;

  Registration? _registration;
  Discovery? _discovery;
  final _peers = <String, DiscoveredPeer>{};
  final _controller = StreamController<List<DiscoveredPeer>>.broadcast();

  Stream<List<DiscoveredPeer>> get peers => _controller.stream;
  List<DiscoveredPeer> get current => _peers.values.toList(growable: false);

  Future<void> start({required int port}) async {
    await stop();
    _registration = await register(Service(
      name: '${identity.displayName}-${identity.id.substring(0, 6)}',
      type: _serviceType,
      port: port,
      txt: {
        'id': _utf8(identity.id),
        'name': _utf8(identity.displayName),
        'pk': _utf8(identity.publicKeyBase64),
      },
    ));
    _discovery = await startDiscovery(_serviceType, autoResolve: true);
    _discovery!.addServiceListener((service, status) {
      if (status == ServiceStatus.found) {
        _onFound(service);
      } else if (status == ServiceStatus.lost) {
        _onLost(service);
      }
    });
  }

  Future<void> stop() async {
    if (_discovery != null) {
      await stopDiscovery(_discovery!);
      _discovery = null;
    }
    if (_registration != null) {
      await unregister(_registration!);
      _registration = null;
    }
    _peers.clear();
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }

  void _onFound(Service s) {
    final txt = s.txt ?? {};
    final id = _readUtf8(txt['id']);
    if (id == null || id == identity.id) return; // skip ourselves
    final host = s.host;
    final port = s.port;
    if (host == null || port == null) return;
    _peers[id] = DiscoveredPeer(
      deviceId: id,
      endpoint: PeerEndpoint(host: host, port: port),
      displayName: _readUtf8(txt['name']) ?? id.substring(0, 6),
      publicKey: _readUtf8(txt['pk']) ?? '',
    );
    _emit();
  }

  void _onLost(Service s) {
    final id = _readUtf8((s.txt ?? {})['id']);
    if (id == null) return;
    if (_peers.remove(id) != null) _emit();
  }

  void _emit() => _controller.add(current);

  static Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));
  static String? _readUtf8(Uint8List? raw) =>
      raw == null ? null : utf8.decode(raw);
}
