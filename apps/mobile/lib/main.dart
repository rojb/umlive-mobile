import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app/app_scope.dart';
import 'app/app_services.dart';
import 'core/log.dart';
import 'l10n/app_localizations.dart';
import 'presentation/routes.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  // The composition root touches SQLite and secure storage, so the binding has
  // to exist before the first plugin call.
  WidgetsFlutterBinding.ensureInitialized();

  final AppServices services;
  try {
    services = await AppServices.bootstrap();
  } on Object catch (error) {
    // Storage that cannot be opened is an environment failure, not a user
    // choice: it is reported and not papered over with a half-working app.
    logEvent('app', {
      'action': 'bootstrap',
      'result': 'failed',
      'error': error.runtimeType.toString(),
    });
    rethrow;
  }

  runApp(UmliveVoiceApp(services: services));

  // FR-MA05: the stored backend is re-probed without user action, after the
  // first frame so a network round trip never holds up startup. The app bar
  // shows the probe in progress and then the state it produced.
  unawaited(services.connection.probeStored());
}

/// Root of the app.
///
/// One locale, Spanish, at launch (PRD-MOBILE.md §7, "Localization"): the
/// locale is a decision, not a preference, so it is pinned here rather than
/// exposed as a setting. Every user-facing string comes from
/// [AppLocalizations] — none is hard-coded in Dart.
class UmliveVoiceApp extends StatelessWidget {
  const UmliveVoiceApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      services: services,
      child: MaterialApp(
        // Localized so the task-switcher label follows the same source of truth
        // as the rest of the copy.
        onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
        theme: buildAppTheme(),
        locale: const Locale('es'),
        supportedLocales: const [Locale('es')],
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        initialRoute: AppRoutes.initialFor(
          hasStoredProfile: services.connection.hasStoredProfile,
        ),
        routes: AppRoutes.table,
      ),
    );
  }
}
