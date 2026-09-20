import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// The on-device database.
///
/// Schema version 1 creates **all four tables** of `docs/architecture.md` §5 at
/// once — `profile`, `registry`, `outbox`, `read_cache` — even though T2 only
/// writes `profile`. That is deliberate: later tasks then add behaviour instead
/// of migrations, and the schema stays a single reviewed statement of what the
/// app persists.
///
/// Version **2** is the first thing that genuinely needed a column, so it is the
/// first version that had to move. `read_cache` was keyed
/// `(profile_id, operation_key)`, and one operation can address many records
/// (`GET /api/cliente/{id}`): the key identified *which operation* read, not
/// *what was read*, so an offline read of `cliente 2` could be answered with
/// `cliente 1`'s body and a fresh-looking age. The key becomes
/// `(profile_id, operation_key, path)`, where `path` is the resolved path the
/// request actually went to.
class AppDatabase {
  AppDatabase(this.database);

  /// The live handle. Repositories receive this and own their own statements.
  final Database database;

  static const String fileName = 'umlive_voice.db';
  static const int schemaVersion = 2;

  static Future<AppDatabase> open({String? path}) async {
    final databasePath =
        path ?? p.join(await getDatabasesPath(), AppDatabase.fileName);
    final database = await openDatabase(
      databasePath,
      version: schemaVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
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
    batch.execute(_readCacheDdl);
    await batch.commit(noResult: true);
  }

  /// Upgrades any older database to [schemaVersion] by rebuilding `read_cache`.
  ///
  /// The cache is **disposable remembered data**, so dropping it is the honest
  /// migration: losing a remembered answer can only make the app ask the
  /// backend, while carrying the old two-column key forward would make it answer
  /// with the wrong record — the exact failure version 2 exists to remove. No
  /// other table is touched: `profile`, `registry` and `outbox` hold state the
  /// app is accountable for, and none of them changed.
  ///
  /// The new DDL is [_readCacheDdl], the *same* string `_onCreate` runs, so a
  /// fresh install and an upgraded one end at exactly the same schema.
  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion >= 2) return;
    await db.execute('DROP TABLE IF EXISTS read_cache');
    await db.execute(_readCacheDdl);
  }

  /// The `read_cache` DDL, shared by `_onCreate` and `_onUpgrade` so both paths
  /// are the same statement.
  ///
  /// `path` is the resolved path of the request, not the operation's path
  /// template: the template is identical for every record of a collection item
  /// route, so it cannot tell `cliente 1` and `cliente 2` apart and must never
  /// be part of the key.
  static const String _readCacheDdl = '''
CREATE TABLE read_cache(
  profile_id    TEXT NOT NULL,
  operation_key TEXT NOT NULL,
  path          TEXT NOT NULL,
  fetched_at    INTEGER NOT NULL,
  response_json TEXT NOT NULL,
  PRIMARY KEY(profile_id, operation_key, path)
)''';
}
