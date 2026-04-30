import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;

import '../data/database.dart';
import 'event_log/device_id.dart';
import 'event_log/event_writer.dart';
import 'identity/device_identity.dart';
import 'mutation_service.dart';
import 'sync/event_applier.dart';
import 'sync/peer_discovery.dart';
import 'sync/sync_engine.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final deviceIdentityProvider = FutureProvider<DeviceIdentity>((ref) async {
  return DeviceIdentity.load();
});

final deviceIdProvider = FutureProvider<DeviceId>((ref) async {
  return DeviceId.load();
});

final eventWriterProvider = FutureProvider<EventWriter>((ref) async {
  final deviceId = await ref.watch(deviceIdProvider.future);
  return EventWriter.create(deviceId: deviceId);
});

final mutationServiceProvider = FutureProvider<MutationService>((ref) async {
  final db = ref.watch(databaseProvider);
  final events = await ref.watch(eventWriterProvider.future);
  return MutationService(db: db, events: events);
});

final eventApplierProvider = FutureProvider<EventApplier>((ref) async {
  final db = ref.watch(databaseProvider);
  final deviceId = await ref.watch(deviceIdProvider.future);
  return EventApplier(db: db, deviceId: deviceId);
});

final syncEngineProvider = FutureProvider<SyncEngine>((ref) async {
  final db = ref.watch(databaseProvider);
  final identity = await ref.watch(deviceIdentityProvider.future);
  final writer = await ref.watch(eventWriterProvider.future);
  final applier = await ref.watch(eventApplierProvider.future);
  final engine = SyncEngine(
    db: db,
    identity: identity,
    writer: writer,
    applier: applier,
  );
  ref.onDispose(engine.dispose);
  return engine;
});

/// Live LAN peers seen via mDNS (whether paired or not).
final discoveredPeersProvider = StreamProvider<List<DiscoveredPeer>>((ref) async* {
  final engine = await ref.watch(syncEngineProvider.future);
  yield engine.discovery.current;
  yield* engine.discovery.peers;
});

/// Paired peers from the DB.
final pairedPeersProvider = StreamProvider<List<Peer>>((ref) {
  final db = ref.watch(databaseProvider);
  return (db.select(db.peers)
        ..orderBy([(t) => OrderingTerm.asc(t.displayName)]))
      .watch();
});

class TodoFilter {
  const TodoFilter({this.listId, this.search = '', this.showDone = true});

  final String? listId;
  final String search;
  final bool showDone;

  TodoFilter copyWith({
    Object? listId = _sentinel,
    String? search,
    bool? showDone,
  }) {
    return TodoFilter(
      listId: identical(listId, _sentinel) ? this.listId : listId as String?,
      search: search ?? this.search,
      showDone: showDone ?? this.showDone,
    );
  }

  static const _sentinel = Object();
}

final todoFilterProvider = StateProvider<TodoFilter>((ref) => const TodoFilter());

final todosProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final filter = ref.watch(todoFilterProvider);

  final query = db.select(db.todos)
    ..where((t) => t.deletedAt.isNull());

  if (filter.listId != null) {
    query.where((t) => t.listId.equals(filter.listId!));
  }
  if (!filter.showDone) {
    query.where((t) => t.done.equals(false));
  }
  if (filter.search.trim().isNotEmpty) {
    final needle = '%${filter.search.trim()}%';
    query.where((t) => t.title.like(needle) | t.description.like(needle));
  }
  query.orderBy([
    (t) => OrderingTerm.asc(t.done),
    (t) => OrderingTerm.desc(t.updatedAt),
  ]);

  return query.watch();
});

final listsProvider = StreamProvider<List<TodoList>>((ref) {
  final db = ref.watch(databaseProvider);
  return (db.select(db.todoLists)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.name)]))
      .watch();
});

final tagsForTodoProvider =
    StreamProvider.family<List<Tag>, String>((ref, todoId) {
  final db = ref.watch(databaseProvider);
  final query = db.select(db.tags).join([
    innerJoin(db.todoTags, db.todoTags.tagId.equalsExp(db.tags.id)),
  ])
    ..where(db.todoTags.todoId.equals(todoId));
  return query.watch().map((rows) => rows.map((r) => r.readTable(db.tags)).toList());
});
