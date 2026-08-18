import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Store-and-forward archive of mutation events, keyed by origin device.
/// Layout mirrors the app's own outbox: `events/<deviceId>/<ts>-<type>-<id>.json`
/// where `<ts>` is the event's createdAt in epoch milliseconds.
///
/// The node never interprets events — conflict resolution (LWW) happens on the
/// devices. Writes are idempotent: the same event always maps to the same
/// filename.
class RelayEventStore {
  RelayEventStore(this.root);

  /// e.g. `<dataDir>/events`
  final Directory root;

  static final _safe = RegExp(r'^[A-Za-z0-9._=-]+$');

  /// Accepts a batch of event JSON maps; returns how many were stored.
  /// Events with missing/unsafe fields are skipped rather than failing the
  /// whole batch.
  Future<int> put(Iterable<Map<String, Object?>> events) async {
    var stored = 0;
    for (final e in events) {
      final id = e['id'];
      final type = e['type'];
      final deviceId = e['deviceId'];
      final createdAt = e['createdAt'];
      if (id is! String ||
          type is! String ||
          deviceId is! String ||
          createdAt is! String) {
        continue;
      }
      // Fields become path segments — refuse anything that could traverse.
      if (!_safe.hasMatch(id) ||
          !_safe.hasMatch(type) ||
          !_safe.hasMatch(deviceId)) {
        continue;
      }
      final ts = DateTime.tryParse(createdAt)?.toUtc().millisecondsSinceEpoch;
      if (ts == null) continue;

      final dir = Directory(p.join(root.path, deviceId));
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, '$ts-$type-$id.json'));
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(e),
        flush: true,
      );
      stored++;
    }
    return stored;
  }

  /// All events (from every origin device) with timestamp strictly after
  /// [sinceMs], ordered chronologically.
  Future<List<Map<String, Object?>>> readSince(int sinceMs) async {
    if (!await root.exists()) return const [];
    final entries = <(int, String, File)>[];
    await for (final deviceDir in root.list(followLinks: false)) {
      if (deviceDir is! Directory) continue;
      await for (final entity in deviceDir.list(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        final base = p.basename(entity.path);
        final ts = int.tryParse(base.split('-').first);
        if (ts == null || ts <= sinceMs) continue;
        entries.add((ts, base, entity));
      }
    }
    entries.sort((a, b) {
      final byTs = a.$1.compareTo(b.$1);
      return byTs != 0 ? byTs : a.$2.compareTo(b.$2);
    });
    final out = <Map<String, Object?>>[];
    for (final (_, _, f) in entries) {
      try {
        out.add(jsonDecode(await f.readAsString()) as Map<String, Object?>);
      } catch (_) {
        /* skip corrupt */
      }
    }
    return out;
  }

  /// Highest event timestamp stored (ms), across all devices.
  Future<int> latestTimestampMs() async {
    if (!await root.exists()) return 0;
    var max = 0;
    await for (final deviceDir in root.list(followLinks: false)) {
      if (deviceDir is! Directory) continue;
      await for (final e in deviceDir.list(followLinks: false)) {
        if (e is! File || !e.path.endsWith('.json')) continue;
        final ts = int.tryParse(p.basename(e.path).split('-').first);
        if (ts != null && ts > max) max = ts;
      }
    }
    return max;
  }

  /// Event counts per origin device (for /status).
  Future<Map<String, int>> countsByDevice() async {
    final counts = <String, int>{};
    if (!await root.exists()) return counts;
    await for (final deviceDir in root.list(followLinks: false)) {
      if (deviceDir is! Directory) continue;
      var n = 0;
      await for (final e in deviceDir.list(followLinks: false)) {
        if (e is File && e.path.endsWith('.json')) n++;
      }
      counts[p.basename(deviceDir.path)] = n;
    }
    return counts;
  }
}
