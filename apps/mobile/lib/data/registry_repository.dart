import 'package:sqflite/sqflite.dart';

/// Owner of the `registry` table.
///
/// T2 only asks the question the reachability state needs — *is there anything
/// cached for this profile?* — because `offlineWithCache` (`FR-MA05`) depends
/// on it. T4 fills the table with the derived registry.
class RegistryRepository {
  RegistryRepository({required this.database});

  final Database database;

  /// True when a registry row exists for [profileId].
  Future<bool> hasRegistry(String profileId) async {
    final rows = await database.query(
      'registry',
      columns: <String>['profile_id'],
      where: 'profile_id = ?',
      whereArgs: <Object?>[profileId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }
}
