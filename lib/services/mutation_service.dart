import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../data/database.dart';
import 'event_log/event.dart';
import 'event_log/event_writer.dart';

/// Single chokepoint for all mutating operations. Every method:
///   1. updates the local Drift DB
///   2. emits a MutationEvent so Phase 2/3 can sync it
///
/// UI must never write to the DB directly — go through here.
class MutationService {
  MutationService({required this.db, required this.events});

  final AppDatabase db;
  final EventWriter events;

  static const _uuid = Uuid();
  String _eventId() => _uuid.v4();
  DateTime _now() => DateTime.now().toUtc();

  Future<void> _emit(
    EventType type,
    String entityId,
    Map<String, Object?> payload,
  ) async {
    final event = MutationEvent(
      id: _eventId(),
      type: type,
      deviceId: events.deviceId.value,
      createdAt: _now(),
      entityId: entityId,
      payload: payload,
    );
    // Mark as processed before writing the file so the importer (which watches
    // the same dir) skips it instead of re-applying our own mutation.
    await db
        .into(db.processedEvents)
        .insertOnConflictUpdate(
          ProcessedEventsCompanion.insert(
            eventId: event.id,
            deviceId: event.deviceId,
          ),
        );
    await events.append(event);
  }

  // ─── Lists ────────────────────────────────────────────────────────────

  Future<TodoList> createList({required String name, String? color}) async {
    final now = _now();
    final id = const Uuid().v4();
    final companion = TodoListsCompanion.insert(
      id: Value(id),
      name: name,
      color: Value(color),
      createdAt: Value(now),
      updatedAt: Value(now),
    );
    await db.into(db.todoLists).insert(companion);
    await _emit(EventType.listCreated, id, {'name': name, 'color': ?color});
    return (await (db.select(
      db.todoLists,
    )..where((t) => t.id.equals(id))).getSingle());
  }

  Future<void> renameList(String id, String name) async {
    final now = _now();
    await (db.update(db.todoLists)..where((t) => t.id.equals(id))).write(
      TodoListsCompanion(name: Value(name), updatedAt: Value(now)),
    );
    await _emit(EventType.listUpdated, id, {'name': name});
  }

  Future<void> deleteList(String id) async {
    final now = _now();
    await (db.update(db.todoLists)..where((t) => t.id.equals(id))).write(
      TodoListsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
    await _emit(EventType.listDeleted, id, {});
  }

  // ─── Todos ────────────────────────────────────────────────────────────

  Future<Todo> createTodo({
    required String title,
    String? description,
    String? listId,
    DateTime? dueAt,
    int priority = 1,
  }) async {
    final now = _now();
    final id = const Uuid().v4();
    final companion = TodosCompanion.insert(
      id: Value(id),
      listId: Value(listId),
      title: title,
      description: Value(description),
      dueAt: Value(dueAt),
      priority: Value(priority),
      createdAt: Value(now),
      updatedAt: Value(now),
    );
    await db.into(db.todos).insert(companion);
    await _emit(EventType.todoCreated, id, {
      'title': title,
      'description': ?description,
      'listId': ?listId,
      if (dueAt != null) 'dueAt': dueAt.toUtc().toIso8601String(),
      'priority': priority,
    });
    return (await (db.select(
      db.todos,
    )..where((t) => t.id.equals(id))).getSingle());
  }

  Future<void> updateTodo(
    String id, {
    String? title,
    String? description,
    String? listId,
    bool? clearListId,
    DateTime? dueAt,
    bool? clearDueAt,
    int? priority,
    bool? done,
  }) async {
    final now = _now();
    final companion = TodosCompanion(
      title: title == null ? const Value.absent() : Value(title),
      description: description == null
          ? const Value.absent()
          : Value(description),
      listId: clearListId == true
          ? const Value(null)
          : (listId == null ? const Value.absent() : Value(listId)),
      dueAt: clearDueAt == true
          ? const Value(null)
          : (dueAt == null ? const Value.absent() : Value(dueAt)),
      priority: priority == null ? const Value.absent() : Value(priority),
      done: done == null ? const Value.absent() : Value(done),
      updatedAt: Value(now),
    );
    await (db.update(db.todos)..where((t) => t.id.equals(id))).write(companion);

    final patch = <String, Object?>{};
    if (title != null) patch['title'] = title;
    if (description != null) patch['description'] = description;
    if (clearListId == true) {
      patch['listId'] = null;
    } else if (listId != null) {
      patch['listId'] = listId;
    }
    if (clearDueAt == true) {
      patch['dueAt'] = null;
    } else if (dueAt != null) {
      patch['dueAt'] = dueAt.toUtc().toIso8601String();
    }
    if (priority != null) patch['priority'] = priority;
    if (done != null) patch['done'] = done;

    await _emit(EventType.todoUpdated, id, patch);
  }

  Future<void> toggleTodo(String id, bool done) => updateTodo(id, done: done);

  Future<void> deleteTodo(String id) async {
    final now = _now();
    await (db.update(db.todos)..where((t) => t.id.equals(id))).write(
      TodosCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
    await _emit(EventType.todoDeleted, id, {});
  }

  // ─── Tags ─────────────────────────────────────────────────────────────

  Future<Tag> ensureTag(String name) async {
    final existing = await (db.select(
      db.tags,
    )..where((t) => t.name.equals(name))).getSingleOrNull();
    if (existing != null) return existing;
    final id = const Uuid().v4();
    await db
        .into(db.tags)
        .insert(TagsCompanion.insert(id: Value(id), name: name));
    return (await (db.select(
      db.tags,
    )..where((t) => t.id.equals(id))).getSingle());
  }

  Future<void> addTagToTodo(String todoId, String tagName) async {
    final tag = await ensureTag(tagName);
    await db
        .into(db.todoTags)
        .insertOnConflictUpdate(
          TodoTagsCompanion.insert(todoId: todoId, tagId: tag.id),
        );
    await _emit(EventType.tagAdded, todoId, {'tag': tagName});
  }

  Future<void> removeTagFromTodo(String todoId, String tagName) async {
    final tag = await (db.select(
      db.tags,
    )..where((t) => t.name.equals(tagName))).getSingleOrNull();
    if (tag == null) return;
    await (db.delete(
      db.todoTags,
    )..where((t) => t.todoId.equals(todoId) & t.tagId.equals(tag.id))).go();
    await _emit(EventType.tagRemoved, todoId, {'tag': tagName});
  }
}
