import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n/app_localizations.dart';
import 'presentation/routes.dart';
import 'theme/app_theme.dart';

void main() {
  runApp(const UmliveVoiceApp());
}

/// Root of the app.
///
/// One locale, Spanish, at launch (PRD-MOBILE.md §7, "Localization"): the
/// locale is a decision, not a preference, so it is pinned here rather than
/// exposed as a setting. Every user-facing string comes from
/// [AppLocalizations] — none is hard-coded in Dart.
class UmliveVoiceApp extends StatelessWidget {
  const UmliveVoiceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
      initialRoute: AppRoutes.initial,
      routes: AppRoutes.table,
    );
  }
}
