import 'registry.dart';

/// What one description added and removed relative to an earlier one
/// (`FR-MA07`).
///
/// Pure, and deliberately about *operations*, not about document bytes: the
/// caller decides whether to compare at all by looking at the document hash,
/// and this answers the question the operator actually asks — what can this
/// backend do now that it could not before, and what can it no longer do.
///
/// Identity is the operation key (`"<METHOD> <path template>"`) for the same
/// reason the registry keys on it: `operationId` is deduplicated by springdoc
/// with an unstable numeric suffix, so a change in the diagram would look like
/// every operation being replaced.
class RegistryDiff {
  const RegistryDiff({required this.added, required this.removed});

  /// Operation keys the new document declares and the previous one did not,
  /// in the new document's order.
  final List<String> added;

  /// Operation keys the previous document declared and the new one does not,
  /// in the previous document's order.
  final List<String> removed;

  /// True when the two descriptions expose the same callable operations.
  bool get isEmpty => added.isEmpty && removed.isEmpty;

  /// Compares two registries operation by operation.
  ///
  /// The lists keep document order instead of being sorted, so the rendered
  /// report reads in the order the backend publishes its endpoints.
  static RegistryDiff between(ApiRegistry previous, ApiRegistry next) {
    final previousKeys = previous.operations
        .map((operation) => operation.key)
        .toSet();
    final nextKeys = next.operations.map((operation) => operation.key).toSet();

    return RegistryDiff(
      added: next.operations
          .map((operation) => operation.key)
          .where((key) => !previousKeys.contains(key))
          .toList(),
      removed: previous.operations
          .map((operation) => operation.key)
          .where((key) => !nextKeys.contains(key))
          .toList(),
    );
  }
}
