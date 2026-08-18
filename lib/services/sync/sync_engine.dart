import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;

import '../../data/database.dart';
import '../blobs/blob_store.dart';
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
    required this.blobs,
  });

  final AppDatabase db;
  final DeviceIdentity identity;
  final EventWriter writer;
  final EventApplier applier;
  final BlobStore blobs;

  late final SyncServer server = SyncServer(
    identity: identity,
    writer: writer,
    blobs: blobs,
    onPeerEvents: _ingestFromPeer,
  );
  late final PeerDiscovery discovery = PeerDiscovery(identity: identity);

  StreamSubscription<List<DiscoveredPeer>>? _discoverySub;
  Timer? _periodic;
  Timer? _maintenance;

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
    // Storage housekeeping: shortly after boot, then twice a day.
    _maintenance = Timer.periodic(
        const Duration(hours: 12), (_) => runMaintenance());
    Timer(const Duration(minutes: 2), runMaintenance);
  }

  Future<void> stop() async {
    _periodic?.cancel();
    _maintenance?.cancel();
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

  /// Set (or clear, with null) a user-configured `host:port` for a peer —
  /// typically its Tailscale IP or MagicDNS name — used when the peer is not
  /// reachable via mDNS (i.e. away from the home LAN).
  Future<void> setStaticEndpoint(String peerId, PeerEndpoint? endpoint) async {
    await (db.update(db.peers)..where((t) => t.id.equals(peerId))).write(
      PeersCompanion(staticEndpoint: Value(endpoint?.toString())),
    );
  }

  /// Trigger a sync against every paired peer. Tries, in order: the live mDNS
  /// endpoint, the configured static (Tailscale) endpoint, then the last known
  /// LAN endpoint — stopping at the first that responds.
  Future<void> syncAllOnce() async {
    final paired = await db.select(db.peers).get();
    final discovered = {for (final p in discovery.current) p.deviceId: p};
    for (final peer in paired) {
      final candidates = <PeerEndpoint>[
        if (discovered[peer.id] != null) discovered[peer.id]!.endpoint,
        if (PeerEndpoint.tryParse(peer.staticEndpoint) != null)
          PeerEndpoint.tryParse(peer.staticEndpoint)!,
        if (PeerEndpoint.tryParse(peer.lastEndpoint) != null)
          PeerEndpoint.tryParse(peer.lastEndpoint)!,
      ];
      final seen = <String>{};
      for (final endpoint in candidates) {
        if (!seen.add(endpoint.toString())) continue;
        if (await _exchangeWith(peer.id, endpoint)) break;
      }
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
  /// than theirs. Returns true if the endpoint responded to either leg.
  Future<bool> _exchangeWith(String peerId, PeerEndpoint endpoint) async {
    final peer = await (db.select(db.peers)..where((t) => t.id.equals(peerId)))
        .getSingleOrNull();
    if (peer == null) return false; // not paired
    var reachable = false;

    // PULL
    try {
      final res = await http
          .get(endpoint.uri('/events').replace(
              queryParameters: {'since': peer.lastSyncMs.toString()}))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        reachable = true;
        final body = jsonDecode(res.body) as Map<String, Object?>;
        final events = ((body['events'] as List?) ?? const [])
            .cast<Map<String, Object?>>();
        if (events.isNotEmpty) {
          await applier.applyAll(events);
        }
        // Fetch bytes for any image blocks whose blob we don't have yet —
        // also self-heals blobs that failed to transfer on a previous cycle.
        await _pullMissingBlobs(endpoint);
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
      if (ours.isEmpty) return reachable;
      final res = await http
          .post(endpoint.uri('/events'),
              headers: {'content-type': 'application/json'},
              body: jsonEncode({'events': ours}))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        reachable = true;
        await _pushBlobs(endpoint, ours);
        final ourLatest = await writer.latestTimestampMs();
        await (db.update(db.peers)..where((t) => t.id.equals(peerId))).write(
          PeersCompanion(lastPushMs: Value(ourLatest)),
        );
      }
    } catch (_) {/* peer offline */}
    return reachable;
  }

  /// Download blobs referenced by live image blocks that are missing locally.
  Future<void> _pullMissingBlobs(PeerEndpoint endpoint) async {
    final imageBlocks = await (db.select(db.noteBlocks)
          ..where((t) => t.type.equals('image') & t.deletedAt.isNull()))
        .get();
    for (final block in imageBlocks) {
      final hash = block.content;
      if (!BlobStore.looksLikeHash(hash) || await blobs.exists(hash)) continue;
      try {
        final res = await http
            .get(endpoint.uri('/blobs/$hash'))
            .timeout(const Duration(seconds: 30));
        if (res.statusCode == 200) {
          await blobs.putVerified(hash, res.bodyBytes);
        }
      } catch (_) {/* try again next cycle */}
    }
  }

  /// Upload blobs referenced by events we just pushed, unless the peer
  /// already has them.
  Future<void> _pushBlobs(
      PeerEndpoint endpoint, List<Map<String, Object?>> pushedEvents) async {
    final hashes = <String>{};
    for (final e in pushedEvents) {
      final type = e['type'];
      if (type is! String || !type.startsWith('note.block.')) continue;
      final payload = (e['payload'] as Map?)?.cast<String, Object?>();
      final content = payload?['content'];
      if (content is String && BlobStore.looksLikeHash(content)) {
        hashes.add(content);
      }
    }
    for (final hash in hashes) {
      final bytes = await blobs.read(hash);
      if (bytes == null) continue;
      try {
        final check = await http
            .get(endpoint.uri('/blobs/$hash/exists'))
            .timeout(const Duration(seconds: 8));
        if (check.statusCode == 200 &&
            (jsonDecode(check.body) as Map)['exists'] == true) {
          continue;
        }
        await http
            .post(endpoint.uri('/blobs/$hash'),
                headers: {'content-type': 'application/octet-stream'},
                body: bytes)
            .timeout(const Duration(seconds: 30));
      } catch (_) {/* peer offline — the pull side will self-heal */}
    }
  }

  /// Storage housekeeping, safe to run at any time:
  ///  - deletes blobs no live image block references (with a 1-day grace
  ///    period for freshly written files);
  ///  - prunes our own event files that every currently-paired peer has
  ///    already received AND that are older than 30 days — so a fresh device
  ///    can still bootstrap recent history from us, and full history from an
  ///    always-on node (which never prunes).
  Future<void> runMaintenance() async {
    try {
      final imageBlocks = await (db.select(db.noteBlocks)
            ..where((t) => t.type.equals('image')))
          .get();
      final referenced = {
        for (final b in imageBlocks)
          if (b.deletedAt == null && BlobStore.looksLikeHash(b.content))
            b.content,
      };
      await blobs.deleteUnreferenced(referenced);
    } catch (_) {/* never let housekeeping break sync */}

    try {
      final paired = await db.select(db.peers).get();
      if (paired.isEmpty) return; // nobody confirmed delivery — keep all
      final delivered =
          paired.map((peer) => peer.lastPushMs).reduce((a, b) => a < b ? a : b);
      final thirtyDaysAgo = DateTime.now()
          .toUtc()
          .subtract(const Duration(days: 30))
          .millisecondsSinceEpoch;
      final cutoff = delivered < thirtyDaysAgo ? delivered : thirtyDaysAgo;
      if (cutoff > 0) await writer.pruneBefore(cutoff);
    } catch (_) {/* never let housekeeping break sync */}
  }

  Future<void> _ingestFromPeer(List<Map<String, Object?>> events) async {
    if (events.isEmpty) return;
    await applier.applyAll(events);
  }
}
