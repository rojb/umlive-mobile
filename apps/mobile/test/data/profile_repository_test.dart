// Unit test for `ProfileRepository.forgetActive()`
// (`odd/tasks/forget-connected-backend.md`, T5): forgetting the active
// connection clears the three secure-storage keys and the `profile` row, and
// forgetting with nothing stored is a no-op that never throws.
//
// `ProfileRepository` takes a real sqflite `Database` and a real
// `FlutterSecureStorage`, and neither one runs against a platform channel on
// the Dart VM this test executes under (the same constraint
// `reference_hint_test.dart` avoided by testing a dependency-free function).
// Both are substituted here with the packages' own substitution points:
// `FlutterSecureStoragePlatform.instance` is set to
// `TestFlutterSecureStoragePlatform`, the in-memory double
// `flutter_secure_storage` ships for exactly this purpose, and `_FakeDatabase`
// implements the three `Database` methods this repository actually calls
// (`insert`, `query`, `delete`), falling back to `noSuchMethod` for the rest
// of the interface the type system otherwise requires.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:umlive_voice/data/profile_repository.dart';
import 'package:umlive_voice/net/backend_address.dart';
import 'package:umlive_voice/net/transport_policy.dart';

void main() {
  late _FakeDatabase database;
  late Map<String, String> secureValues;
  late ProfileRepository repository;

  setUp(() {
    database = _FakeDatabase();
    secureValues = <String, String>{};
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      secureValues,
    );
    repository = ProfileRepository(
      database: database,
      secureStorage: const FlutterSecureStorage(),
    );
  });

  group('forgetActive', () {
    test('clears the secure-storage keys and the profile row', () async {
      final address = BackendAddress(
        base: Uri.https('example.com'),
        transport: TransportSecurity.secure,
      );
      final stored = await repository.save(address: address, token: 'secret');
      final id = stored.profile.id;

      // Guards the test itself: `forgetActive` must have something real to
      // clear, or a bug that does nothing would pass trivially.
      expect(secureValues, isNotEmpty);
      expect(database.rowsOf('profile'), hasLength(1));

      await repository.forgetActive();

      expect(secureValues, isEmpty);
      expect(database.rowsOf('profile'), isEmpty);
      expect(await repository.loadActive(), isNull);
      // Named explicitly, not just "the map is empty": the three keys
      // `FR-MA01` fixes are what a leftover row would be found under.
      expect(secureValues.containsKey('profile.active_id'), isFalse);
      expect(secureValues.containsKey('profile.$id.base_url'), isFalse);
      expect(secureValues.containsKey('profile.$id.bearer_token'), isFalse);
    });

    test('forgetting with nothing stored is a no-op and does not throw', () async {
      await expectLater(repository.forgetActive(), completes);

      expect(secureValues, isEmpty);
      expect(database.rowsOf('profile'), isEmpty);
    });

    test('forgetting twice in a row does not throw', () async {
      final address = BackendAddress(
        base: Uri.https('example.com'),
        transport: TransportSecurity.secure,
      );
      await repository.save(address: address);

      await repository.forgetActive();
      await expectLater(repository.forgetActive(), completes);

      expect(secureValues, isEmpty);
      expect(database.rowsOf('profile'), isEmpty);
    });
  });
}

/// A `Database` fake that keeps rows in memory, table by table.
///
/// `ProfileRepository` only ever calls `insert`, `query` and `delete`, and
/// always with either no `where` clause or `where: 'id = ?'` — this fake
/// implements exactly that subset. `noSuchMethod` satisfies the rest of the
/// abstract `Database` interface the type system requires but this repository
/// never calls, the same relaxation `mockito`-style fakes rely on.
class _FakeDatabase implements Database {
  final Map<String, List<Map<String, Object?>>> _tables =
      <String, List<Map<String, Object?>>>{};

  /// Test-only introspection: the stored rows of [table], for asserting what
  /// a repository call actually left behind.
  List<Map<String, Object?>> rowsOf(String table) =>
      List<Map<String, Object?>>.unmodifiable(
        _tables[table] ?? const <Map<String, Object?>>[],
      );

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    final rows = _tables.putIfAbsent(table, () => <Map<String, Object?>>[]);
    // Mirrors `ConflictAlgorithm.replace` against the `id` primary key, the
    // only conflict algorithm `ProfileRepository.save` ever passes.
    rows.removeWhere((row) => row['id'] == values['id']);
    rows.add(Map<String, Object?>.from(values));
    return rows.length;
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    final matched = _filter(_tables[table], where: where, whereArgs: whereArgs);
    return limit == null ? matched : matched.take(limit).toList();
  }

  @override
  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    final rows = _tables[table];
    if (rows == null) return 0;
    final matched = _filter(rows, where: where, whereArgs: whereArgs);
    rows.removeWhere(matched.contains);
    return matched.length;
  }

  /// The one filter shape this file's repositories ever ask for: every row,
  /// or every row whose `id` equals the single bound argument.
  List<Map<String, Object?>> _filter(
    List<Map<String, Object?>>? rows, {
    String? where,
    List<Object?>? whereArgs,
  }) {
    final source = rows ?? const <Map<String, Object?>>[];
    if (where == null) return List<Map<String, Object?>>.from(source);
    if (where != 'id = ?' || whereArgs == null || whereArgs.isEmpty) {
      throw UnsupportedError('Unsupported where clause in fake: $where');
    }
    final id = whereArgs.first;
    return source.where((row) => row['id'] == id).toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
