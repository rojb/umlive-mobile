import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/tokens.dart';
import '../routes.dart';
import '../widgets/app_background.dart';

/// Settings (`FR-MG01`): locale, technical mode, backend.
///
/// Two of the three rows here are decisions the app has already made, not
/// preferences to be explored: locale is fixed because it is not a user choice
/// at launch (UX spec, Pass 4 "Defaults introduced"), and the backend row is the
/// only way to reach Connect, because the conversation surface never changes the
/// backend (Pass 3, affordance rules).
///
/// Technical mode is the exception, and it is the one thing on this screen a
/// person is meant to change (`T23`, `FR-ME06`): the switch reports the mode's
/// real state and flips it, and the turn blocks it reveals appear on the
/// conversation surface immediately — on the turns already there, because the
/// mode is persistent across turns (Pass 3). It is still off on every launch,
/// which is the product's default and not this screen's decision.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    // The same mode the conversation surface reads: one shared object from the
    // composition root, so the switch and the turns cannot disagree.
    final technicalMode = AppScope.of(context).technicalMode;

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: Text(l10n.settingsTitle)),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            children: [
              ListTile(
                leading: const Icon(Icons.translate_outlined),
                title: Text(l10n.settingsLanguageLabel),
                trailing: Text(
                  l10n.settingsLanguageValue,
                  style: textTheme.bodySmall,
                ),
                // Read-only: there is no second locale to switch to yet.
              ),
              const Divider(),
              ListenableBuilder(
                // The switch is the mode's own state, so it is rebuilt by the
                // mode: flipping it anywhere — this row today, anything later —
                // leaves the switch telling the truth.
                listenable: technicalMode,
                builder: (context, _) => SwitchListTile(
                  secondary: const Icon(Icons.terminal_outlined),
                  title: Text(l10n.settingsTechnicalModeLabel),
                  subtitle: Text(l10n.settingsTechnicalModeHelp),
                  // Live since `T23`: the operator's own request to see the
                  // machinery, and the only thing that ever turns it on.
                  value: technicalMode.enabled,
                  onChanged: (_) => technicalMode.toggle(),
                ),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: Text(l10n.settingsBackendLabel),
                subtitle: Text(l10n.connectExplanation),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).pushNamed(AppRoutes.connect),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
