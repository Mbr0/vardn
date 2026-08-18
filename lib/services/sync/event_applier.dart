import 'package:drift/drift.dart';

import '../../data/database.dart';
import '../event_log/device_id.dart';
import '../event_log/event.dart';

class ApplyResult {
  ApplyResult({this.applied = 0, this.skipped = 0, this.errors = 0});
  int applied;
  int skipped;
  int errors;
}

/// Applies serialized [MutationEvent]s to the local DB with last-write-wins
/// semantics. Idempotent via the [ProcessedEvents] table.
class EventApplier {
  EventApplier({required this.db, required this.deviceId});

  final AppDatabase db;
  final DeviceId deviceId;

  Future<ApplyResult> applyAll(Iterable<Map<String, Object?>> events) async {
    final result = ApplyResult();
    for (final json in events) {
      try {
        final applied = await applyOne(json);
        if (applied) {
          result.applied++;
        } else {
          result.skipped++;
        }
      } catch (_) {
        result.errors++;
      }
    }
    return result;
  }

  /// Returns true if the event changed local state.
  Future<bool> applyOne(Map<String, Object?> json) async {
    final eventId = json['id'] as String;
    final already = await (db.select(db.processedEvents)
          ..where((t) => t.eventId.equals(eventId)))
        .getSingleOrNull();
    if (already != null) return false;

    final type = EventType.values.firstWhere(
      (t) => t.wire == json['type'],
      orElse: () => throw FormatException('Unknown event type: ${json['type']}'),
    );
    final originDevice = json['deviceId'] as String;
    final createdAt = DateTime.parse(json['createdAt'] as String).toUtc();
    final entityId = json['entityId'] as String;
    final payload = (json['payload'] as Map?)?.cast<String, Object?>() ?? const {};

    final isOwnEvent = originDevice == deviceId.value;
    if (!isOwnEvent) {
      await _apply(type, entityId, createdAt, payload);
    }

    await db.into(db.processedEvents).insertOnConflictUpdate(
          ProcessedEventsCompanion.insert(
            eventId: eventId,
            deviceId: originDevice,
          ),
        );
    return !isOwnEvent;
  }

  Future<void> _apply(
    EventType type,
    String entityId,
    DateTime eventAt,
    Map<String, Object?> payload,
  ) async {
    switch (type) {
      case EventType.todoCreated:
      case EventType.todoUpdated:
        await _upsertTodo(entityId, eventAt, payload);
      case EventType.todoDeleted:
        await _tombstoneTodo(entityId, eventAt);
      case EventType.listCreated:
      case EventType.listUpdated:
        await _upsertList(entityId, eventAt, payload);
      case EventType.listDeleted:
        await _tombstoneList(entityId, eventAt);
      case EventType.tagAdded:
        final name = payload['tag'] as String?;
        if (name != null) await _addTag(entityId, name);
      case EventType.tagRemoved:
        final name = payload['tag'] as String?;
        if (name != null) await _removeTag(entityId, name);
      case EventType.noteCreated:
      case EventType.noteUpdated:
        await _upsertNote(entityId, eventAt, payload);
      case EventType.noteDeleted:
        await _tombstoneNote(entityId, eventAt);
      case EventType.blockCreated:
      case EventType.blockUpdated:
        await _upsertBlock(entityId, eventAt, payload);
      case EventType.blockDeleted:
        await _tombstoneBlock(entityId, eventAt);
    }
  }

  Future<void> _upsertNote(
      String id, DateTime eventAt, Map<String, Object?> payload) async {
    final existing = await (db.select(db.notes)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (existing == null) {
      await db.into(db.notes).insert(
            NotesCompanion.insert(
              id: Value(id),
              title: Value((payload['title'] as String?) ?? ''),
              color: Value(payload['color'] as String?),
              pinned: Value((payload['pinned'] as bool?) ?? false),
              createdAt: Value(eventAt),
              updatedAt: Value(eventAt),
            ),
          );
      return;
    }
    if (eventAt.isBefore(existing.updatedAt)) return;
    await (db.update(db.notes)..where((t) => t.id.equals(id))).write(
      NotesCompanion(
        title: payload.containsKey('title')
            ? Value(payload['title'] as String)
            : const Value.absent(),
        color: payload.containsKey('color')
            ? Value(payload['color'] as String?)
            : const Value.absent(),
        pinned: payload.containsKey('pinned')
            ? Value(payload['pinned'] as bool)
            : const Value.absent(),
        updatedAt: Value(eventAt),
      ),
    );
  }

  Future<void> _tombstoneNote(String id, DateTime eventAt) async {
    final existing = await (db.select(db.notes)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (existing == null) {
      await db.into(db.notes).insert(
            NotesCompanion.insert(
              id: Value(id),
              createdAt: Value(eventAt),
              updatedAt: Value(eventAt),
              deletedAt: Value(eventAt),
            ),
          );
      return;
    }
    await (db.update(db.notes)..where((t) => t.id.equals(id))).write(
      NotesCompanion(deletedAt: Value(eventAt), updatedAt: Value(eventAt)),
    );
  }

  Future<void> _upsertBlock(
      String id, DateTime eventAt, Map<String, Object?> payload) async {
    final existing = await (db.select(db.noteBlocks)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (existing == null) {
      final noteId = payload['noteId'] as String?;
      // A block update can arrive before its create; without the noteId we
      // can't place it, so drop it — the eventual create carries everything.
      if (noteId == null) return;
      await db.into(db.noteBlocks).insert(
            NoteBlocksCompanion.insert(
              id: Value(id),
              noteId: noteId,
              type: Value((payload['type'] as String?) ?? 'text'),
              content: Value((payload['content'] as String?) ?? ''),
              checked: Value((payload['checked'] as bool?) ?? false),
              position: Value((payload['position'] as num?)?.toDouble() ?? 0),
              createdAt: Value(eventAt),
              updatedAt: Value(eventAt),
            ),
          );
      return;
    }
    if (eventAt.isBefore(existing.updatedAt)) return;
    await (db.update(db.noteBlocks)..where((t) => t.id.equals(id))).write(
      NoteBlocksCompanion(
        type: payload.containsKey('type')
            ? Value(payload['type'] as String)
            : const Value.absent(),
        content: payload.containsKey('content')
            ? Value(payload['content'] as String)
            : const Value.absent(),
        checked: payload.containsKey('checked')
            ? Value(payload['checked'] as bool)
            : const Value.absent(),
        position: payload.containsKey('position')
            ? Value((payload['position'] as num).toDouble())
            : const Value.absent(),
        updatedAt: Value(eventAt),
      ),
    );
  }

  Future<void> _tombstoneBlock(String id, DateTime eventAt) async {
    final existing = await (db.select(db.noteBlocks)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (existing == null) {
      // Unknown note — park the tombstone under a placeholder so a late
      // create is still superseded (same convergence trick as todos).
      await db.into(db.noteBlocks).insert(
            NoteBlocksCompanion.insert(
              id: Value(id),
              noteId: '',
              createdAt: Value(eventAt),
              updatedAt: Value(eventAt),
              deletedAt: Value(eventAt),
            ),
          );
      return;
    }
    await (db.update(db.noteBlocks)..where((t) => t.id.equals(id))).write(
      NoteBlocksCompanion(deletedAt: Value(eventAt), updatedAt: Value(eventAt)),
    );
  }

  Future<void> _upsertTodo(
      String id, DateTime eventAt, Map<String, Object?> payload) async {
    final existing = await (db.select(db.todos)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (existing == null) {
      await db.into(db.todos).insert(
            TodosCompanion.insert(
              id: Value(id),
              title: (payload['title'] as String?) ?? '(untitled)',
              description: Value(payload['description'] as String?),
              listId: Value(payload['listId'] as String?),
              dueAt: Value(_parseDateTime(payload['dueAt'])),
              priority: Value((payload['priority'] as num?)?.toInt() ?? 1),
              done: Value((payload['done'] as bool?) ?? false),
              createdAt: Value(eventAt),
              updatedAt: Value(eventAt),
            ),
          );
      return;
    }
    if (eventAt.isBefore(existing.updatedAt)) return;
    await (db.update(db.todos)..where((t) => t.id.equals(id))).write(
      TodosCompanion(
        title: payload.containsKey('title')
            ? Value(payload['title'] as String)
            : const Value.absent(),
        description: payload.containsKey('description')
            ? Value(payload['description'] as String?)
            : const Value.absent(),
        listId: payload.containsKey('listId')
            ? Value(payload['listId'] as String?)
            : const Value.absent(),
        dueAt: payload.containsKey('dueAt')
            ? Value(_parseDateTime(payload['dueAt']))
            : const Value.absent(),
        priority: payload.containsKey('priority')
            ? Value((payload['priority'] as num).toInt())
            : const Value.absent(),
        done: payload.containsKey('done')
            ? Value(payload['done'] as bool)
            : const Value.absent(),
        updatedAt: Value(eventAt),
      ),
    );
  }

  Future<void> _tombstoneTodo(String id, DateTime eventAt) async {
    final existing = await (db.select(db.todos)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (existing == null) {
      await db.into(db.todos).insert(
            TodosCompanion.insert(
              id: Value(id),
              title: '(deleted)',
              createdAt: Value(eventAt),
              updatedAt: Value(eventAt),
              deletedAt: Value(eventAt),
            ),
          );
      return;
    }
    await (db.update(db.todos)..where((t) => t.id.equals(id))).write(
      TodosCompanion(
        deletedAt: Value(eventAt),
        updatedAt: Value(eventAt),
      ),
    );
  }

  Future<void> _upsertList(
      String id, DateTime eventAt, Map<String, Object?> payload) async {
    final existing = await (db.select(db.todoLists)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (existing == null) {
      await db.into(db.todoLists).insert(
            TodoListsCompanion.insert(
              id: Value(id),
              name: (payload['name'] as String?) ?? '(unnamed)',
              color: Value(payload['color'] as String?),
              createdAt: Value(eventAt),
              updatedAt: Value(eventAt),
            ),
          );
      return;
    }
    if (eventAt.isBefore(existing.updatedAt)) return;
    await (db.update(db.todoLists)..where((t) => t.id.equals(id))).write(
      TodoListsCompanion(
        name: payload.containsKey('name')
            ? Value(payload['name'] as String)
            : const Value.absent(),
        color: payload.containsKey('color')
            ? Value(payload['color'] as String?)
            : const Value.absent(),
        updatedAt: Value(eventAt),
      ),
    );
  }

  Future<void> _tombstoneList(String id, DateTime eventAt) async {
    final existing = await (db.select(db.todoLists)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (existing == null) {
      await db.into(db.todoLists).insert(
            TodoListsCompanion.insert(
              id: Value(id),
              name: '(deleted)',
              createdAt: Value(eventAt),
              updatedAt: Value(eventAt),
              deletedAt: Value(eventAt),
            ),
          );
      return;
    }
    await (db.update(db.todoLists)..where((t) => t.id.equals(id))).write(
      TodoListsCompanion(
        deletedAt: Value(eventAt),
        updatedAt: Value(eventAt),
      ),
    );
  }

  Future<void> _addTag(String todoId, String name) async {
    final tag = await (db.select(db.tags)..where((t) => t.name.equals(name)))
        .getSingleOrNull();
    String tagId;
    if (tag == null) {
      tagId = _hashId('tag:$name');
      await db.into(db.tags).insert(TagsCompanion.insert(
            id: Value(tagId),
            name: name,
          ));
    } else {
      tagId = tag.id;
    }
    await db.into(db.todoTags).insertOnConflictUpdate(
          TodoTagsCompanion.insert(todoId: todoId, tagId: tagId),
        );
  }

  Future<void> _removeTag(String todoId, String name) async {
    final tag = await (db.select(db.tags)..where((t) => t.name.equals(name)))
        .getSingleOrNull();
    if (tag == null) return;
    await (db.delete(db.todoTags)
          ..where((t) => t.todoId.equals(todoId) & t.tagId.equals(tag.id)))
        .go();
  }

  DateTime? _parseDateTime(Object? raw) {
    if (raw is! String) return null;
    return DateTime.parse(raw).toUtc();
  }

  String _hashId(String input) {
    var h = 0xcbf29ce484222325;
    for (final c in input.codeUnits) {
      h ^= c;
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return 'tag_${h.toRadixString(16).padLeft(16, '0')}';
  }
}
