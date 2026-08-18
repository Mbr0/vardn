import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'device_id.dart';
import 'event.dart';

/// Writes mutation events to disk as a local outbox/audit log.
/// Layout: `app_support/events/deviceId/timestamp-type-eventId.json`.
/// The HTTP server reads from here when peers ask for events since a watermark.
class EventWriter {
  EventWriter({required this.deviceId, required this.directory});

  final DeviceId deviceId;
  final Directory directory;

  static Future<EventWriter> create({DeviceId? deviceId}) async {
    final id = deviceId ?? await DeviceId.load();
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'events', id.value));
    await dir.create(recursive: true);
    return EventWriter(deviceId: id, directory: dir);
  }

  Future<File> append(MutationEvent event) async {
    final ts = event.createdAt.toUtc().millisecondsSinceEpoch;
    final filename = '$ts-${event.type.wire}-${event.id}.json';
    final file = File(p.join(directory.path, filename));
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(event.toJson()),
      flush: true,
    );
    return file;
  }

  /// Reads our own events emitted strictly after [since] (millisecond
  /// timestamps), ordered chronologically. Used to serve sync pulls.
  Future<List<Map<String, Object?>>> readSince(int sinceMs) async {
    if (!await directory.exists()) return const [];
    final files = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final base = p.basename(entity.path);
      final ts = int.tryParse(base.split('-').first);
      if (ts == null || ts <= sinceMs) continue;
      files.add(entity);
    }
    files.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    final out = <Map<String, Object?>>[];
    for (final f in files) {
      try {
        out.add(jsonDecode(await f.readAsString()) as Map<String, Object?>);
      } catch (_) {
        /* skip corrupt */
      }
    }
    return out;
  }

  /// Deletes our own event files with timestamps strictly before [cutoffMs].
  /// Only call with a cutoff every currently-paired peer has already been
  /// pushed past — pruned events can never be served again. Returns the
  /// number of files removed.
  Future<int> pruneBefore(int cutoffMs) async {
    if (!await directory.exists()) return 0;
    var removed = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final ts = int.tryParse(p.basename(entity.path).split('-').first);
      if (ts == null || ts >= cutoffMs) continue;
      try {
        await entity.delete();
        removed++;
      } catch (_) {/* keep going */}
    }
    return removed;
  }

  /// Highest event timestamp we've emitted (ms). Useful as our own watermark.
  Future<int> latestTimestampMs() async {
    if (!await directory.exists()) return 0;
    var max = 0;
    await for (final e in directory.list(followLinks: false)) {
      if (e is! File || !e.path.endsWith('.json')) continue;
      final ts = int.tryParse(p.basename(e.path).split('-').first);
      if (ts != null && ts > max) max = ts;
    }
    return max;
  }
}
