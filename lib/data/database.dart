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
class Peers extends Table {
  TextColumn get id => text()(); // peer device id (= public key fingerprint)
  TextColumn get publicKey => text()();
  TextColumn get displayName => text().withDefault(const Constant(''))();
  TextColumn get lastEndpoint => text().nullable()();
  IntColumn get lastSyncMs => integer().withDefault(const Constant(0))();
  IntColumn get lastPushMs => integer().withDefault(const Constant(0))();
  DateTimeColumn get pairedAt => dateTime().clientDefault(_utcNow)();
  DateTimeColumn get lastSeenAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [TodoLists, Todos, Tags, TodoTags, ProcessedEvents, Peers])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
      : super(executor ?? driftDatabase(name: 'vardn'));

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) await m.createTable(processedEvents);
          if (from < 3) await m.createTable(peers);
        },
      );
}
