import '../net/backend_address.dart';

/// The non-secret half of a stored connection.
///
/// The address itself and the shared bearer token are **not** here: they live
/// in `flutter_secure_storage` (`docs/architecture.md` §5, and `PRD-MOBILE.md`
/// §7, "Security — data at rest").
class ConnectionProfile {
  const ConnectionProfile({
    required this.id,
    required this.createdAt,
    this.label,
    this.lastConnectedAt,
  });

  final String id;

  /// A human-friendly name for the backend. Unused at T2 — `FR-MA09` (several
  /// saved backends) is the reason the column exists.
  final String? label;

  final int createdAt;
  final int? lastConnectedAt;

  factory ConnectionProfile.fromRow(Map<String, Object?> row) {
    return ConnectionProfile(
      id: row['id']! as String,
      label: row['label'] as String?,
      createdAt: (row['created_at']! as num).toInt(),
      lastConnectedAt: (row['last_connected_at'] as num?)?.toInt(),
    );
  }
}

/// A complete restorable connection: the row plus the two secrets.
class StoredConnection {
  const StoredConnection({
    required this.profile,
    required this.address,
    this.token,
  });

  final ConnectionProfile profile;
  final BackendAddress address;

  /// The shared bearer token of `FR-MF03`, or null when the backend is open.
  final String? token;
}
