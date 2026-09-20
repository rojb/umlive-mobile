import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../core/log.dart';

/// Where one queued write is in its life (`FR-MD02`).
///
/// The [name] of a value is what the `status` column holds, so the persisted
/// spelling and the Dart spelling cannot drift apart.
enum OutboxStatus {
  /// Persisted and not yet attempted. This is the state a write reaches the
  /// queue in.
  pending,

  /// A drain (`T16`) has taken this item and is sending it. A row left in this
  /// state by a force-kill is outstanding work, not a sent one.
  inFlight,

  /// An attempt failed and the item is still queued (`FR-MD04`): it keeps its
  /// place in the order and carries the reason of the last failure.
  failed,
}

/// What kind of write one queued item is.
enum OutboxKind {
  /// A create (`POST`). Not idempotent, so it carries an idempotency key.
  create,

  /// A delete (`DELETE`). Idempotent by nature: replaying it is safe, so it
  /// carries no key.
  delete,
}

/// One row of the `outbox` table, as it was stored.
///
/// A value: every column is a field, there is no setter and no `copyWith`, and
/// a state change is a repository call that writes the row again — never a
/// mutation of an item already in a caller's hand.
class OutboxItem {
  const OutboxItem({
    required this.id,
    required this.profileId,
    required this.seq,
    required this.operationKey,
    required this.method,
    required this.path,
    required this.pathParameters,
    required this.body,
    required this.idempotencyKey,
    required this.createdAt,
    required this.status,
    required this.attempts,
    required this.lastError,
    required this.kind,
  });

  /// `outbox.id`: the primary key, and the handle every other method takes.
  final int id;

  /// `outbox.profile_id`: which stored backend this item belongs to.
  final String profileId;

  /// `outbox.seq`: the monotonic issue order **within** [profileId]. Assigned
  /// as `MAX(seq) + 1` inside the insert's transaction, so it only ever grows
  /// and is never a timestamp.
  final int seq;

  /// `outbox.operation_id`: the registry's operation key
  /// (`"<METHOD> <path template>"`), never a route assembled by hand
  /// (`FR-MA03`).
  final String operationKey;

  /// `outbox.method`: the HTTP verb, exactly as the registry declared it.
  final String method;

  /// `outbox.path`: the resolved path — the template with its path parameters
  /// substituted — because that is what has to be sent again.
  final String path;

  /// `outbox.path_params_json`, decoded: the values that were bound to the
  /// operation's declared path parameters. Empty when the operation declares
  /// none.
  final Map<String, String> pathParameters;

  /// `outbox.body_json`, decoded: the JSON body the write carried, or null for
  /// a write with no body (a delete).
  final Object? body;

  /// `outbox.idempotency_key`: 32 hex characters, generated for a
  /// [OutboxKind.create] and null for a [OutboxKind.delete]. A replay of a
  /// create has to be recognisable as the same create; a replay of a delete is
  /// safe to repeat.
  final String? idempotencyKey;

  /// `outbox.created_at`, in milliseconds since the epoch.
  final int createdAt;

  /// `outbox.status`, decoded to its enum.
  final OutboxStatus status;

  /// `outbox.attempts`: how many sends have failed so far. Starts at 0 and is
  /// incremented by [OutboxRepository.markFailed].
  final int attempts;

  /// `outbox.last_error`: why the last attempt failed, or null when none has.
  final String? lastError;

  /// `outbox.kind`, decoded to its enum.
  final OutboxKind kind;
}

/// Owner of the `outbox` table (`FR-MD02`, `FR-MD06`).
///
/// **This is the only place a queued write is persisted.** The table already
/// exists at schema version 1 (`app_database.dart`), so this repository adds
/// behaviour and no migration. It follows the house pattern of
/// `RegistryRepository`: it takes the open [Database], every operation is a
/// method, and no SQL escapes this file.
///
/// A write reaches the queue **before** any acknowledgement reaches the
/// operator (`FR-MD02`), and the row survives a force-kill (`FR-MD06`): the
/// queue is the record that the command did not happen yet. The order is a
/// strictly ascending [OutboxItem.seq] and nothing else — never a timestamp —
/// so a retry keeps the place it was issued in and a later command can never
/// overtake an earlier one (`FR-MD04`).
class OutboxRepository {
  OutboxRepository({required this.database});

  final Database database;

  /// One source of randomness for idempotency keys. `Random.secure()` because
  /// the key is the only thing that lets a replayed create be recognised as
  /// the same create by a backend that has already received it.
  static final Random _random = Random.secure();

  /// The `action` values a state change is logged with, plus the line a row
  /// that cannot be decoded gets. The log never carries a body and never
  /// carries a captured value: the queue stores the operator's data, and the
  /// log gets at most its size.
  static const String _actionEnqueue = 'enqueue';
  static const String _actionInFlight = 'in_flight';
  static const String _actionSent = 'sent';
  static const String _actionFailed = 'failed';
  static const String _actionRemove = 'remove';
  static const String _actionUnreadable = 'unreadable';

  /// Persists one write and returns the stored item.
  ///
  /// The monotonic [OutboxItem.seq] is read and assigned in a single
  /// transaction, so two enqueues of the same profile can never share a
  /// sequence and the order is the order of issue. The key is generated for a
  /// create only: a create is not idempotent, while a delete is and repeating
  /// it is harmless, so a delete stores no key.
  Future<OutboxItem> enqueue({
    required String profileId,
    required String operationKey,
    required String method,
    required String path,
    Map<String, String> pathParameters = const <String, String>{},
    Object? body,
    required OutboxKind kind,
  }) async {
    final createdAt = DateTime.now().millisecondsSinceEpoch;
    final idempotencyKey = kind == OutboxKind.create
        ? _newIdempotencyKey()
        : null;
    final pathParametersJson = pathParameters.isEmpty
        ? null
        : jsonEncode(pathParameters);
    final bodyJson = body == null ? null : jsonEncode(body);

    final item = await database.transaction<OutboxItem>((txn) async {
      final rows = await txn.rawQuery(
        'SELECT MAX(seq) AS max_seq FROM outbox WHERE profile_id = ?',
        <Object?>[profileId],
      );
      final previous = (rows.first['max_seq'] as num?)?.toInt();
      final seq = (previous ?? 0) + 1;
      final id = await txn.insert('outbox', <String, Object?>{
        'profile_id': profileId,
        'seq': seq,
        'operation_id': operationKey,
        'method': method,
        'path': path,
        'path_params_json': pathParametersJson,
        'body_json': bodyJson,
        'idempotency_key': idempotencyKey,
        'created_at': createdAt,
        'status': OutboxStatus.pending.name,
        'attempts': 0,
        'last_error': null,
        'kind': kind.name,
      });
      return OutboxItem(
        id: id,
        profileId: profileId,
        seq: seq,
        operationKey: operationKey,
        method: method,
        path: path,
        pathParameters: Map<String, String>.unmodifiable(pathParameters),
        body: body,
        idempotencyKey: idempotencyKey,
        createdAt: createdAt,
        status: OutboxStatus.pending,
        attempts: 0,
        lastError: null,
        kind: kind,
      );
    });

    logEvent('outbox', <String, Object?>{
      'action': _actionEnqueue,
      'id': item.id,
      'seq': item.seq,
      'operation': item.operationKey,
      'kind': item.kind.name,
      'attempts': item.attempts,
      // The size of what was captured, never the capture: this is the
      // operator's data, and it belongs in the queue and nowhere else.
      'bodyBytes': bodyJson?.length ?? 0,
    });
    return item;
  }

  /// The outstanding items of [profileId], in issue order.
  ///
  /// `pending` and `failed` are both outstanding — a failed item is a retry
  /// waiting for the backend, not a discard — and both come first by
  /// [OutboxItem.seq] ascending. That strict ascending order is what keeps a
  /// retry in its original place (`FR-MD04`): a later command can never
  /// overtake an earlier one, which is the whole point of a queue rather than
  /// a set of parallel attempts.
  Future<List<OutboxItem>> pending(String profileId) async {
    final rows = await database.query(
      'outbox',
      where: 'profile_id = ? AND status IN (?, ?)',
      whereArgs: <Object?>[
        profileId,
        OutboxStatus.pending.name,
        OutboxStatus.failed.name,
      ],
      orderBy: 'seq ASC',
    );
    return <OutboxItem>[
      for (final row in rows)
        if (_toItem(row) case final OutboxItem item) item,
    ];
  }

  /// How many outstanding items [profileId] has.
  ///
  /// The count of exactly what [pending] returns, and the number the launch
  /// line `[umlive][outbox] kind=pending count=N` reports, so a force-kill can
  /// be proven to have left the queue intact (`FR-MD06`).
  Future<int> pendingCount(String profileId) async {
    final rows = await database.rawQuery(
      'SELECT COUNT(*) AS count FROM outbox '
      'WHERE profile_id = ? AND status IN (?, ?)',
      <Object?>[
        profileId,
        OutboxStatus.pending.name,
        OutboxStatus.failed.name,
      ],
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  /// Marks [id] as being sent by a drain (`T16`).
  ///
  /// A row left in this state is outstanding work: the app was killed mid-send
  /// and the backend's answer was never seen.
  Future<void> markInFlight(int id) async {
    final item = await _item(id);
    if (item == null) return;
    await database.update(
      'outbox',
      <String, Object?>{'status': OutboxStatus.inFlight.name},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    _logState(_actionInFlight, item);
  }

  /// Removes a sent item from the queue.
  ///
  /// A sent item is not outstanding, and the queue holds only outstanding work:
  /// the row is deleted rather than left with a status nothing would ever read
  /// again. [markFailed] is the other half of one send attempt.
  Future<void> markSent(int id) async {
    final item = await _item(id);
    if (item == null) return;
    await database.delete(
      'outbox',
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    _logState(_actionSent, item);
  }

  /// Marks [id] as failed, with [reason], and counts the attempt.
  ///
  /// The item stays queued: a failure is not a discard, so it keeps its place
  /// and its `attempts` grows. The reason is stored so `T18`'s queue screen can
  /// name it, and it is a protocol-level description of the failure — never a
  /// captured value.
  Future<void> markFailed(int id, String reason) async {
    final item = await _item(id);
    if (item == null) return;
    await database.rawUpdate(
      'UPDATE outbox SET status = ?, attempts = attempts + 1, last_error = ? '
      'WHERE id = ?',
      <Object?>[OutboxStatus.failed.name, reason, id],
    );
    _logState(_actionFailed, item, attempts: item.attempts + 1);
  }

  /// Removes [id] from the queue: the cancel path `T18` will use.
  ///
  /// A cancelled write is one that will never be sent, and the operator is the
  /// one who says so — nothing here decides it on its own.
  Future<void> remove(int id) async {
    final item = await _item(id);
    if (item == null) return;
    await database.delete(
      'outbox',
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    _logState(_actionRemove, item);
  }

  /// Drops every outstanding item of [profileId].
  ///
  /// The same shape as `RegistryRepository.clear`: used when the app is pointed
  /// at a different backend, because a queue belonging to another backend would
  /// otherwise be sent to this one. One `remove` line is written per row, so a
  /// bulk clear leaves the same trace a per-item cancel does.
  Future<void> clear(String profileId) async {
    final items = await pending(profileId);
    await database.delete(
      'outbox',
      where: 'profile_id = ?',
      whereArgs: <Object?>[profileId],
    );
    for (final item in items) {
      _logState(_actionRemove, item);
    }
  }

  /// The stored row for [id], or null when there is none.
  Future<OutboxItem?> _item(int id) async {
    final rows = await database.query(
      'outbox',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _toItem(rows.first);
  }

  /// One stored row as an [OutboxItem], or null when it cannot be decoded.
  ///
  /// A row this build cannot read is reported and skipped rather than thrown
  /// on: the queue is read on the launch path, and a single unreadable row must
  /// not be able to take the whole app down with it.
  OutboxItem? _toItem(Map<String, Object?> row) {
    final id = (row['id'] as num?)?.toInt();
    final profileId = row['profile_id'];
    final seq = (row['seq'] as num?)?.toInt();
    final operationKey = row['operation_id'];
    final method = row['method'];
    final path = row['path'];
    final kind = row['kind'];
    if (id == null ||
        profileId is! String ||
        seq == null ||
        operationKey is! String ||
        method is! String ||
        path is! String ||
        kind is! String) {
      _logUnreadable(id, 'row_not_text');
      return null;
    }
    final pathParameters = _decodePathParameters(id, row['path_params_json']);
    return OutboxItem(
      id: id,
      profileId: profileId,
      seq: seq,
      operationKey: operationKey,
      method: method,
      path: path,
      pathParameters: pathParameters,
      body: _decodeBody(id, row['body_json']),
      idempotencyKey: row['idempotency_key'] as String?,
      createdAt: (row['created_at'] as num?)?.toInt() ?? 0,
      status: _status(row['status']),
      attempts: (row['attempts'] as num?)?.toInt() ?? 0,
      lastError: row['last_error'] as String?,
      kind: OutboxKind.values.firstWhere(
        (value) => value.name == kind,
        orElse: () => OutboxKind.create,
      ),
    );
  }

  /// The `path_params_json` column, decoded. An unreadable column is reported
  /// and treated as no parameter, because a parameter cannot be invented.
  Map<String, String> _decodePathParameters(int? id, Object? column) {
    if (column is! String || column.isEmpty) return const <String, String>{};
    try {
      final decoded = jsonDecode(column);
      if (decoded is Map) {
        return Map<String, String>.unmodifiable(<String, String>{
          for (final entry in decoded.entries)
            entry.key.toString(): entry.value.toString(),
        });
      }
      _logUnreadable(id, 'path_parameters_not_object');
      return const <String, String>{};
    } on Object catch (error) {
      _logUnreadable(id, error.runtimeType.toString());
      return const <String, String>{};
    }
  }

  /// The `body_json` column, decoded. An unreadable column is reported and
  /// treated as no body rather than sent as an empty one.
  Object? _decodeBody(int? id, Object? column) {
    if (column is! String || column.isEmpty) return null;
    try {
      return jsonDecode(column);
    } on Object catch (error) {
      _logUnreadable(id, error.runtimeType.toString());
      return null;
    }
  }

  /// The stored `status` as its enum, defaulting to `pending` when the column
  /// holds something this build does not know: an unknown status is outstanding
  /// work as far as the queue is concerned.
  OutboxStatus _status(Object? column) {
    if (column is! String) return OutboxStatus.pending;
    return OutboxStatus.values.firstWhere(
      (value) => value.name == column,
      orElse: () => OutboxStatus.pending,
    );
  }

  /// One line per state change. The fields are exactly the ones a reader of
  /// `adb logcat` needs to follow one item's life; the body and the bound
  /// values are never among them.
  void _logState(String action, OutboxItem item, {int? attempts}) {
    logEvent('outbox', <String, Object?>{
      'action': action,
      'id': item.id,
      'seq': item.seq,
      'operation': item.operationKey,
      'kind': item.kind.name,
      'attempts': attempts ?? item.attempts,
    });
  }

  /// The line a row that could not be decoded gets. Not a state change: nothing
  /// about the row was changed, and the reader needs to know the queue lost
  /// sight of one item.
  void _logUnreadable(int? id, String reason) {
    logEvent('outbox', <String, Object?>{
      'action': _actionUnreadable,
      'id': id,
      'reason': reason,
    });
  }

  /// 32 hex characters from `Random.secure()`: 16 random bytes, two hex digits
  /// each.
  static String _newIdempotencyKey() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}
