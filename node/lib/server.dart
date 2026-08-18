import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'event_store.dart';
import 'identity.dart';

/// Speaks the same HTTP protocol as the app's SyncServer, so phones treat the
/// node as just another paired peer:
///   GET  /identity          → {id, publicKey, displayName}
///   GET  /events?since=`<ms>` → {events: [...], latestMs} (merged, all devices)
///   POST /events            → {accepted: n}
///   GET  /status            → uptime/counters (node-only convenience)
///
/// Transport security is delegated to the network: run this bound to a
/// Tailscale interface (or on a LAN you trust) — same trust model as the app.
class NodeServer {
  NodeServer({
    required this.identity,
    required this.store,
  });

  final NodeIdentity identity;
  final RelayEventStore store;
  final DateTime _startedAt = DateTime.now().toUtc();

  HttpServer? _server;
  int? get port => _server?.port;

  Future<void> start({required Object address, required int port}) async {
    final router = Router()
      ..get('/identity', _identityHandler)
      ..get('/events', _eventsGetHandler)
      ..post('/events', _eventsPostHandler)
      ..get('/status', _statusHandler);
    _server = await shelf_io.serve(router.call, address, port);
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    await s?.close(force: true);
  }

  Response _identityHandler(Request _) => _json({
        'id': identity.id,
        'publicKey': identity.publicKeyBase64,
        'displayName': identity.displayName,
      });

  Future<Response> _eventsGetHandler(Request req) async {
    final since = int.tryParse(req.url.queryParameters['since'] ?? '0') ?? 0;
    return _json({
      'events': await store.readSince(since),
      'latestMs': await store.latestTimestampMs(),
    });
  }

  Future<Response> _eventsPostHandler(Request req) async {
    try {
      final body = await req.readAsString();
      final json = jsonDecode(body) as Map<String, Object?>;
      final events =
          ((json['events'] as List?) ?? const []).cast<Map<String, Object?>>();
      final accepted = await store.put(events);
      return _json({'accepted': accepted});
    } on FormatException {
      return Response.badRequest(body: 'invalid JSON');
    }
  }

  Future<Response> _statusHandler(Request _) async => _json({
        'id': identity.id,
        'displayName': identity.displayName,
        'startedAt': _startedAt.toIso8601String(),
        'latestMs': await store.latestTimestampMs(),
        'eventsByDevice': await store.countsByDevice(),
      });

  static Response _json(Object data) => Response.ok(jsonEncode(data),
      headers: {'content-type': 'application/json'});
}
