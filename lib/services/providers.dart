import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;

import '../data/database.dart';
import 'blobs/blob_store.dart';
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

final blobStoreProvider = FutureProvider<BlobStore>((ref) async {
  return BlobStore.create();
});

final syncEngineProvider = FutureProvider<SyncEngine>((ref) async {
  final db = ref.watch(databaseProvider);
  final identity = await ref.watch(deviceIdentityProvider.future);
  final writer = await ref.watch(eventWriterProvider.future);
  final applier = await ref.watch(eventApplierProvider.future);
  final blobs = await ref.watch(blobStoreProvider.future);
  final engine = SyncEngine(
    db: db,
    identity: identity,
    writer: writer,
    applier: applier,
    blobs: blobs,
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

/// Search text for the notes tab.
final noteSearchProvider = StateProvider<String>((ref) => '');

/// Live notes, pinned first then most recently updated. Search matches the
/// title or any block's content.
final notesProvider = StreamProvider<List<Note>>((ref) {
  final db = ref.watch(databaseProvider);
  final search = ref.watch(noteSearchProvider).trim();

  final query = db.select(db.notes)..where((t) => t.deletedAt.isNull());
  if (search.isNotEmpty) {
    final needle = '%$search%';
    final matching = db.selectOnly(db.noteBlocks)
      ..addColumns([db.noteBlocks.noteId])
      ..where(db.noteBlocks.content.like(needle) &
          db.noteBlocks.deletedAt.isNull());
    query.where((t) => t.title.like(needle) | t.id.isInQuery(matching));
  }
  query.orderBy([
    (t) => OrderingTerm.desc(t.pinned),
    (t) => OrderingTerm.desc(t.updatedAt),
  ]);
  return query.watch();
});

/// One live note (null once deleted).
final noteProvider = StreamProvider.family<Note?, String>((ref, noteId) {
  final db = ref.watch(databaseProvider);
  return (db.select(db.notes)
        ..where((t) => t.id.equals(noteId) & t.deletedAt.isNull()))
      .watchSingleOrNull();
});

/// Live, ordered blocks of one note.
final noteBlocksProvider =
    StreamProvider.family<List<NoteBlock>, String>((ref, noteId) {
  final db = ref.watch(databaseProvider);
  return (db.select(db.noteBlocks)
        ..where((t) => t.noteId.equals(noteId) & t.deletedAt.isNull())
        ..orderBy([
          (t) => OrderingTerm.asc(t.position),
          (t) => OrderingTerm.asc(t.createdAt),
        ]))
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
