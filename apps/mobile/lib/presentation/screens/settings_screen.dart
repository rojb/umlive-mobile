import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/tokens.dart';
import '../routes.dart';
import '../widgets/app_background.dart';

/// Settings (`FR-MG01`): locale, technical mode, backend.
///
/// Every row here is a decision the app has already made, not a preference to
/// be explored. Locale is fixed because it is not a user choice at launch (UX
/// spec, Pass 4 "Defaults introduced"); technical mode is off until T23 wires
/// it; and the backend row is the only way to reach Connect, because the
/// conversation surface never changes the backend (Pass 3, affordance rules).
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;

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
              SwitchListTile(
                secondary: const Icon(Icons.terminal_outlined),
                title: Text(l10n.settingsTechnicalModeLabel),
                subtitle: Text(l10n.settingsTechnicalModeHelp),
                // Locked off rather than hidden: the row is part of the app's
                // shape, but nothing may imply it works (T23).
                value: false,
                onChanged: null,
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
