import 'package:flutter/widgets.dart';

import 'app_services.dart';

/// Exposes [AppServices] to the widget tree.
///
/// Deliberately an `InheritedWidget` and nothing more: the app has exactly one
/// shared object graph and one `ChangeNotifier` factory, so a state-management
/// package would add a vocabulary without removing a line of code.
class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.services, required super.child});

  final AppServices services;

  /// The shared services above [context].
  ///
  /// Throws in debug when called with a context that has no [AppScope] above
  /// it, because that is a wiring mistake and not a runtime condition.
  static AppServices of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(
      scope != null,
      'AppScope.of() was called with a context outside the AppScope subtree.',
    );
    return scope!.services;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      !identical(services, oldWidget.services);
}
