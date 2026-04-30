import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;

import '../../data/database.dart';
import '../event_log/event_writer.dart';
import '../identity/device_identity.dart';
import 'event_applier.dart';
import 'peer_discovery.dart';
import 'peer_endpoint.dart';
import 'sync_server.dart';

class SyncEngine {
  SyncEngine({
    required this.db,
    required this.identity,
    required this.writer,
    required this.applier,
  });

  final AppDatabase db;
  final DeviceIdentity identity;
  final EventWriter writer;
  final EventApplier applier;

  late final SyncServer server = SyncServer(
    identity: identity,
    writer: writer,
    onPeerEvents: _ingestFromPeer,
  );
  late final PeerDiscovery discovery = PeerDiscovery(identity: identity);

  StreamSubscription<List<DiscoveredPeer>>? _discoverySub;
  Timer? _periodic;

  Future<void> start() async {
    await server.start();
    await discovery.start(port: server.port!);
    _discoverySub = discovery.peers.listen((peers) async {
      for (final p in peers) {
        await _maybeRefreshEndpoint(p);
        await _exchangeWith(p.deviceId, p.endpoint);
      }
    });
    // Periodic re-sync in case mDNS events are missed.
    _periodic = Timer.periodic(const Duration(seconds: 30), (_) => syncAllOnce());
  }

  Future<void> stop() async {
    _periodic?.cancel();
    await _discoverySub?.cancel();
    await discovery.stop();
    await server.stop();
  }

  Future<void> dispose() async {
    await stop();
    await discovery.dispose();
  }

  /// Fetch identity from a candidate endpoint. Used by the pairing flow
  /// before the peer is in the DB yet.
  Future<Map<String, Object?>?> fetchIdentity(PeerEndpoint endpoint) async {
    try {
      final res =
          await http.get(endpoint.uri('/identity')).timeout(const Duration(seconds: 4));
      if (res.statusCode != 200) return null;
      return jsonDecode(res.body) as Map<String, Object?>;
    } catch (_) {
      return null;
    }
  }

  /// Add or update a peer record after the user confirms pairing.
  Future<void> savePeer({
    required String id,
    required String publicKey,
    required String displayName,
    PeerEndpoint? endpoint,
  }) async {
    await db.into(db.peers).insertOnConflictUpdate(
          PeersCompanion.insert(
            id: id,
            publicKey: publicKey,
            displayName: Value(displayName),
            lastEndpoint: Value(endpoint?.toString()),
          ),
        );
  }

  Future<void> unpair(String peerId) async {
    await (db.delete(db.peers)..where((t) => t.id.equals(peerId))).go();
  }

  /// Trigger a sync against every peer we've ever discovered, using their last
  /// known endpoint. No-op for peers we have no endpoint for.
  Future<void> syncAllOnce() async {
    final paired = await db.select(db.peers).get();
    final discovered = {for (final p in discovery.current) p.deviceId: p};
    for (final peer in paired) {
      final live = discovered[peer.id];
      final endpoint = live?.endpoint ?? _parseEndpoint(peer.lastEndpoint);
      if (endpoint == null) continue;
      await _exchangeWith(peer.id, endpoint);
    }
  }

  Future<void> _maybeRefreshEndpoint(DiscoveredPeer p) async {
    await (db.update(db.peers)..where((t) => t.id.equals(p.deviceId))).write(
      PeersCompanion(
        lastEndpoint: Value(p.endpoint.toString()),
        lastSeenAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  /// Pull peer events newer than our watermark, then push our events newer
  /// than theirs.
  Future<void> _exchangeWith(String peerId, PeerEndpoint endpoint) async {
    final peer = await (db.select(db.peers)..where((t) => t.id.equals(peerId)))
        .getSingleOrNull();
    if (peer == null) return; // not paired

    // PULL
    try {
      final res = await http
          .get(endpoint.uri('/events').replace(
              queryParameters: {'since': peer.lastSyncMs.toString()}))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body) as Map<String, Object?>;
        final events = ((body['events'] as List?) ?? const [])
            .cast<Map<String, Object?>>();
        if (events.isNotEmpty) {
          await applier.applyAll(events);
        }
        final latest = (body['latestMs'] as num?)?.toInt() ?? peer.lastSyncMs;
        if (latest > peer.lastSyncMs) {
          await (db.update(db.peers)..where((t) => t.id.equals(peerId))).write(
            PeersCompanion(
              lastSyncMs: Value(latest),
              lastSeenAt: Value(DateTime.now().toUtc()),
            ),
          );
        }
      }
    } catch (_) {/* peer offline, try later */}

    // PUSH events newer than our last push watermark for this peer.
    try {
      final ours = await writer.readSince(peer.lastPushMs);
      if (ours.isEmpty) return;
      final res = await http
          .post(endpoint.uri('/events'),
              headers: {'content-type': 'application/json'},
              body: jsonEncode({'events': ours}))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final ourLatest = await writer.latestTimestampMs();
        await (db.update(db.peers)..where((t) => t.id.equals(peerId))).write(
          PeersCompanion(lastPushMs: Value(ourLatest)),
        );
      }
    } catch (_) {/* peer offline */}
  }

  Future<void> _ingestFromPeer(List<Map<String, Object?>> events) async {
    if (events.isEmpty) return;
    await applier.applyAll(events);
  }

  static PeerEndpoint? _parseEndpoint(String? s) {
    if (s == null) return null;
    final parts = s.split(':');
    if (parts.length != 2) return null;
    final port = int.tryParse(parts[1]);
    if (port == null) return null;
    return PeerEndpoint(host: parts[0], port: port);
  }
}
