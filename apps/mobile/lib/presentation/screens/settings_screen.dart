import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/tokens.dart';
import '../connection_controller.dart';
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
    // The same connection state Connect edits, for the same reason.
    final connection = AppScope.of(context).connection;

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
              ListenableBuilder(
                // The row follows the connection, so it cannot keep announcing
                // an empty state after one is stored — or the stored address
                // after it changes.
                listenable: connection,
                builder: (context, _) => Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.dns_outlined),
                      title: Text(l10n.settingsBackendLabel),
                      // The address itself, once there is one: it is the
                      // answer to "which backend is this?", and it needs no
                      // copy around it. `connectExplanation` stays for the one
                      // case it describes truthfully — nothing stored yet.
                      subtitle: Text(
                        connection.address?.display ?? l10n.connectExplanation,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () =>
                          Navigator.of(context).pushNamed(AppRoutes.connect),
                    ),
                    // Nothing is stored yet to forget: the row would be a
                    // destructive control with no target, so it is withheld
                    // rather than shown disabled.
                    if (connection.hasStoredProfile)
                      ListTile(
                        leading: const Icon(
                          Icons.link_off,
                          color: AppColors.danger,
                        ),
                        title: Text(
                          l10n.settingsForgetBackendLabel,
                          style: const TextStyle(color: AppColors.danger),
                        ),
                        subtitle: Text(l10n.settingsForgetBackendHelp),
                        onTap: () => unawaited(
                          _confirmAndForget(context, connection),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Asks for confirmation and forgets the connected backend only when it is
  /// given, then lands on Connect with no way back into this screen.
  ///
  /// The same shape `queue_screen.dart`'s `_confirmAndCancel` uses for its own
  /// destructive action: a confirmation, then the effect, and nothing in
  /// between assumes the answer. `pushNamedAndRemoveUntil` mirrors the Connect
  /// screen's own success path (`connect_screen.dart`), so Android's back
  /// gesture cannot return to a Settings screen describing a backend that no
  /// longer exists.
  Future<void> _confirmAndForget(
    BuildContext context,
    ConnectionController connection,
  ) async {
    // Read fresh, at the moment the dialog opens: an item enqueued a moment
    // earlier has to be counted, and a stale figure would under-promise what
    // the confirmation is about to lose.
    final outstanding = await connection.outstandingOperationCount();
    if (!context.mounted) return;

    final confirmed = await _confirmForget(context, outstanding);
    if (!confirmed) return;

    await connection.forget();
    if (!context.mounted) return;
    Navigator.of(
      context,
    ).pushNamedAndRemoveUntil(AppRoutes.connect, (route) => false);
  }

  /// The confirmation itself: title, what forgetting actually means — including
  /// the outstanding count when there is one — and two explicit choices of
  /// unequal weight, the destructive one never pre-selected (UX spec Pass 3,
  /// the same rule `queue_screen.dart`'s confirmation follows).
  Future<bool> _confirmForget(BuildContext context, int outstanding) async {
    final l10n = AppLocalizations.of(context);
    final answer = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.settingsForgetBackendConfirmTitle),
        content: Text(
          outstanding == 0
              ? l10n.settingsForgetBackendConfirmBody
              : l10n.settingsForgetBackendConfirmBodyWithOutstanding(
                  outstanding,
                ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.settingsForgetBackendCancelAction),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: Text(l10n.settingsForgetBackendConfirmAction),
          ),
        ],
      ),
    );
    // Dismissing the dialog by tapping outside it is not an answer, and the
    // safe reading of no answer is to keep the connection.
    return answer ?? false;
  }
}
