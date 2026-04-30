import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import '../event_log/event_writer.dart';
import '../identity/device_identity.dart';

/// HTTP server peers hit to fetch our events and push us theirs.
/// Phase 2a: plain HTTP, no auth — LAN only. Phase 2b will wrap payloads in
/// X25519+ChaCha20.
class SyncServer {
  SyncServer({
    required this.identity,
    required this.writer,
    required this.onPeerEvents,
  });

  final DeviceIdentity identity;
  final EventWriter writer;
  final Future<void> Function(List<Map<String, Object?>> events) onPeerEvents;

  HttpServer? _server;
  int? get port => _server?.port;
  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    final router = Router()
      ..get('/identity', _identityHandler)
      ..get('/events', _eventsGetHandler)
      ..post('/events', _eventsPostHandler);
    _server = await shelf_io.serve(router.call, InternetAddress.anyIPv4, 0);
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    await s?.close(force: true);
  }

  Response _identityHandler(Request _) {
    return Response.ok(
      jsonEncode({
        'id': identity.id,
        'publicKey': identity.publicKeyBase64,
        'displayName': identity.displayName,
      }),
      headers: {'content-type': 'application/json'},
    );
  }

  Future<Response> _eventsGetHandler(Request req) async {
    final since = int.tryParse(req.url.queryParameters['since'] ?? '0') ?? 0;
    final events = await writer.readSince(since);
    return Response.ok(
      jsonEncode({
        'events': events,
        'latestMs': await writer.latestTimestampMs(),
      }),
      headers: {'content-type': 'application/json'},
    );
  }

  Future<Response> _eventsPostHandler(Request req) async {
    final body = await req.readAsString();
    final json = jsonDecode(body) as Map<String, Object?>;
    final events =
        ((json['events'] as List?) ?? const []).cast<Map<String, Object?>>();
    await onPeerEvents(events);
    return Response.ok(jsonEncode({'accepted': events.length}),
        headers: {'content-type': 'application/json'});
  }
}
