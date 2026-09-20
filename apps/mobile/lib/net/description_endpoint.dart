/// The one route this app is allowed to know by heart.
///
/// `FR-MA02` fixes it: springdoc publishes the backend's OpenAPI description at
/// this conventional path. It is not a discovered route — everything else the
/// app calls comes from the registry derived out of the document fetched here,
/// so no other path may be hard-coded (`FR-MA03`).
abstract final class DescriptionEndpoint {
  static const String path = '/v3/api-docs';

  /// The description URL for [base], which carries no path of its own.
  static Uri of(Uri base) => base.replace(path: path);
}
