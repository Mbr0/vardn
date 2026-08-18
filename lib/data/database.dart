import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:uuid/uuid.dart';

part 'database.g.dart';

const _uuid = Uuid();
String _newId() => _uuid.v4();
DateTime _utcNow() => DateTime.now().toUtc();

class TodoLists extends Table {
  TextColumn get id => text().clientDefault(_newId)();
  TextColumn get name => text()();
  TextColumn get color => text().nullable()();
  DateTimeColumn get createdAt => dateTime().clientDefault(_utcNow)();
  DateTimeColumn get updatedAt => dateTime().clientDefault(_utcNow)();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class Todos extends Table {
  TextColumn get id => text().clientDefault(_newId)();
  TextColumn get listId => text().nullable().references(TodoLists, #id)();
  TextColumn get title => text()();
  TextColumn get description => text().nullable()();
  DateTimeColumn get dueAt => dateTime().nullable()();
  IntColumn get priority => integer().withDefault(const Constant(1))();
  BoolColumn get done => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().clientDefault(_utcNow)();
  DateTimeColumn get updatedAt => dateTime().clientDefault(_utcNow)();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class Tags extends Table {
  TextColumn get id => text().clientDefault(_newId)();
  TextColumn get name => text().unique()();
  DateTimeColumn get createdAt => dateTime().clientDefault(_utcNow)();

  @override
  Set<Column> get primaryKey => {id};
}

class TodoTags extends Table {
  TextColumn get todoId =>
      text().references(Todos, #id, onDelete: KeyAction.cascade)();
  TextColumn get tagId =>
      text().references(Tags, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {todoId, tagId};
}

/// A note is a container of ordered blocks (see [NoteBlocks]).
class Notes extends Table {
  TextColumn get id => text().clientDefault(_newId)();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get color => text().nullable()();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().clientDefault(_utcNow)();
  DateTimeColumn get updatedAt => dateTime().clientDefault(_utcNow)();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One piece of a note: a paragraph of text, a checklist item, or a link.
/// `position` is a float so blocks can be reordered by inserting between
/// neighbours without renumbering (fractional indexing).
class NoteBlocks extends Table {
  TextColumn get id => text().clientDefault(_newId)();
  TextColumn get noteId => text().references(Notes, #id)();
  TextColumn get type => text().withDefault(const Constant('text'))();
  TextColumn get content => text().withDefault(const Constant(''))();
  BoolColumn get checked => boolean().withDefault(const Constant(false))();
  RealColumn get position => real().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().clientDefault(_utcNow)();
  DateTimeColumn get updatedAt => dateTime().clientDefault(_utcNow)();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Tracks event ids we've already applied (own + imported) so import is idempotent.
class ProcessedEvents extends Table {
  TextColumn get eventId => text()();
  TextColumn get deviceId => text()();
  DateTimeColumn get processedAt => dateTime().clientDefault(_utcNow)();

  @override
  Set<Column> get primaryKey => {eventId};
}

/// Paired peers we sync with. `publicKey` is the X25519 public key (base64).
/// `lastSyncMs` is the highest event timestamp we've successfully pulled from them.
/// `staticEndpoint` is a user-configured `host:port` (e.g. a Tailscale IP or
/// MagicDNS name) used when the peer is not visible via mDNS.
class Peers extends Table {
  TextColumn get id => text()(); // peer device id (= public key fingerprint)
  TextColumn get publicKey => text()();
  TextColumn get displayName => text().withDefault(const Constant(''))();
  TextColumn get lastEndpoint => text().nullable()();
  TextColumn get staticEndpoint => text().nullable()();
  IntColumn get lastSyncMs => integer().withDefault(const Constant(0))();
  IntColumn get lastPushMs => integer().withDefault(const Constant(0))();
  DateTimeColumn get pairedAt => dateTime().clientDefault(_utcNow)();
  DateTimeColumn get lastSeenAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [
  TodoLists,
  Todos,
  Tags,
  TodoTags,
  Notes,
  NoteBlocks,
  ProcessedEvents,
  Peers,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
      : super(executor ?? driftDatabase(name: 'vardn'));

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) await m.createTable(processedEvents);
          if (from < 3) await m.createTable(peers);
          if (from < 4) await m.addColumn(peers, peers.staticEndpoint);
          if (from < 5) {
            await m.createTable(notes);
            await m.createTable(noteBlocks);
          }
        },
      );
}
