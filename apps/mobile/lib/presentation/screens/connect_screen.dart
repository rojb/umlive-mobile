import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/tokens.dart';
import '../widgets/app_background.dart';

/// Connect (`FR-MG01`): the one screen the app shows when there is no usable
/// backend.
///
/// T1 renders the empty state only — one address field and the explanation. The
/// field accepts text but is not wired to anything: storage, the reachability
/// probe and discovery arrive in T2 and T3, and the QR pairing path of
/// `FR-MA08` alongside them.
class ConnectScreen extends StatelessWidget {
  const ConnectScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: Text(l10n.connectTitle)),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.connectExplanation, style: textTheme.titleMedium),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  l10n.connectHelp,
                  style: textTheme.bodyMedium?.copyWith(
                    color: AppColors.textMuted,
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                Text(l10n.connectFieldLabel, style: textTheme.labelLarge),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  // Inert in T1: the value is neither stored nor submitted.
                  // T2 adds the controller, storage and the reachability probe;
                  // T3 adds discovery; FR-MA08 adds the QR path next to it.
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(hintText: l10n.connectFieldHint),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
