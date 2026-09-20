import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// The on-device database.
///
/// Schema version 1 creates **all four tables** of `docs/architecture.md` §5 at
/// once — `profile`, `registry`, `outbox`, `read_cache` — even though T2 only
/// writes `profile`. That is deliberate: later tasks then add behaviour instead
/// of migrations, and the schema stays a single reviewed statement of what the
/// app persists.
class AppDatabase {
  AppDatabase(this.database);

  /// The live handle. Repositories receive this and own their own statements.
  final Database database;

  static const String fileName = 'umlive_voice.db';
  static const int schemaVersion = 1;

  static Future<AppDatabase> open({String? path}) async {
    final databasePath =
        path ?? p.join(await getDatabasesPath(), AppDatabase.fileName);
    final database = await openDatabase(
      databasePath,
      version: schemaVersion,
      onCreate: _onCreate,
    );
    return AppDatabase(database);
  }

  Future<void> close() => database.close();

  static Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();
    batch.execute('''
CREATE TABLE profile(
  id                TEXT PRIMARY KEY,
  base_url          TEXT NOT NULL,
  label             TEXT,
  created_at        INTEGER NOT NULL,
  last_connected_at INTEGER
)''');
    batch.execute('''
CREATE TABLE registry(
  profile_id       TEXT PRIMARY KEY,
  document_hash    TEXT NOT NULL,
  document_json    TEXT NOT NULL,
  derived_json     TEXT NOT NULL,
  openapi_version  TEXT,
  fetched_at       INTEGER NOT NULL
)''');
    batch.execute('''
CREATE TABLE outbox(
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  profile_id      TEXT NOT NULL,
  seq             INTEGER NOT NULL,
  operation_id    TEXT NOT NULL,
  method          TEXT NOT NULL,
  path            TEXT NOT NULL,
  path_params_json TEXT,
  body_json       TEXT,
  idempotency_key TEXT,
  created_at      INTEGER NOT NULL,
  status          TEXT NOT NULL,
  attempts        INTEGER NOT NULL DEFAULT 0,
  last_error      TEXT,
  kind            TEXT NOT NULL
)''');
    batch.execute('''
CREATE TABLE read_cache(
  profile_id    TEXT NOT NULL,
  operation_key TEXT NOT NULL,
  fetched_at    INTEGER NOT NULL,
  response_json TEXT NOT NULL,
  PRIMARY KEY(profile_id, operation_key)
)''');
    await batch.commit(noResult: true);
  }
}
