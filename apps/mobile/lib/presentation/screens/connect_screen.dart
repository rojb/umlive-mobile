import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../l10n/app_localizations.dart';
import '../../net/backend_address.dart';
import '../../net/reachability.dart';
import '../../theme/tokens.dart';
import '../connection_controller.dart';
import '../routes.dart';
import '../widgets/app_background.dart';
import '../widgets/reachability_indicator.dart';

/// Connect (`FR-MG01`, `FR-MA01`, `FR-MA05`).
///
/// One address, one optional token behind an advanced affordance, one action.
/// The screen owns the text fields and nothing else: normalization, storage and
/// the probe all live in [ConnectionController].
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();

  bool _advancedOpen = false;
  bool _prefilled = false;

  /// The typed text, normalized as it changes, so the cleartext warning appears
  /// before the user commits to the address.
  BackendAddress? _typedAddress;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_prefilled) return;
    _prefilled = true;
    final stored = AppScope.of(context).connection.address;
    if (stored != null) {
      _addressController.text = stored.display;
      _typedAddress = stored;
    }
  }

  @override
  void dispose() {
    _addressController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final connection = AppScope.of(context).connection;

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: Text(l10n.connectTitle)),
        body: SafeArea(
          child: ListenableBuilder(
            listenable: connection,
            builder: (context, _) => SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: connection.isProbing
                  ? _buildLoading(context, l10n, connection)
                  : _buildForm(context, l10n, connection),
            ),
          ),
        ),
      ),
    );
  }

  /// UX spec, Pass 5 — Connection *Loading*: the address is echoed, progress is
  /// shown, and cancel is always available.
  Widget _buildLoading(
    BuildContext context,
    AppLocalizations l10n,
    ConnectionController connection,
  ) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.connectLoadingEcho(connection.address?.display ?? ''),
          style: textTheme.titleMedium,
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: AppSpacing.md),
            Text(l10n.connectProgress, style: textTheme.bodyMedium),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),
        OutlinedButton(
          onPressed: connection.cancel,
          child: Text(l10n.connectCancel),
        ),
      ],
    );
  }

  Widget _buildForm(
    BuildContext context,
    AppLocalizations l10n,
    ConnectionController connection,
  ) {
    final textTheme = Theme.of(context).textTheme;
    final problem = connection.addressProblem;
    final cleartext =
        (_typedAddress?.isCleartext ?? false) || connection.showsCleartextWarning;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // UX spec, Pass 4 — first launch: an address and nothing else.
        Text(l10n.connectExplanation, style: textTheme.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        Text(
          l10n.connectHelp,
          style: textTheme.bodyMedium?.copyWith(color: AppColors.textMuted),
        ),
        const SizedBox(height: AppSpacing.xl),
        Text(l10n.connectFieldLabel, style: textTheme.labelLarge),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _addressController,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          autocorrect: false,
          onChanged: _onAddressChanged,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(hintText: l10n.connectFieldHint),
        ),
        if (problem != null) ...[
          const SizedBox(height: AppSpacing.sm),
          _ProblemNote(text: _problemSentence(l10n, problem)),
        ],
        const SizedBox(height: AppSpacing.md),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _advancedOpen = !_advancedOpen),
            icon: const Icon(Icons.key_outlined),
            label: Text(
              _advancedOpen
                  ? l10n.connectAdvancedHide
                  : l10n.connectAdvancedReveal,
            ),
          ),
        ),
        if (_advancedOpen) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(l10n.connectTokenLabel, style: textTheme.labelLarge),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _tokenController,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(hintText: l10n.connectTokenHint),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            l10n.connectTokenHelp,
            style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
        ],
        if (cleartext) ...[
          const SizedBox(height: AppSpacing.md),
          _CleartextWarning(
            text: l10n.connectCleartextWarning(
              _typedAddress?.base.host ?? connection.address?.base.host ?? '',
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        FilledButton(
          onPressed: _submit,
          child: Text(l10n.connectSubmit),
        ),
        if (connection.reachability != ReachabilityState.neverConnected) ...[
          const SizedBox(height: AppSpacing.xl),
          const ReachabilityIndicator(),
        ],
      ],
    );
  }

  void _onAddressChanged(String value) {
    AppScope.of(context).connection.clearAddressProblem();
    final outcome = BackendAddressParser.parse(value);
    setState(() {
      _typedAddress = outcome is AddressAccepted ? outcome.address : null;
    });
  }

  Future<void> _submit() async {
    final connection = AppScope.of(context).connection;
    final navigator = Navigator.of(context);
    final usable = await connection.connect(
      rawAddress: _addressController.text,
      token: _tokenController.text,
    );
    if (!mounted) return;
    // Only a backend that answered (or one whose earlier answer is cached)
    // leads into the conversation; a refusal stays here with its reason.
    if (usable) {
      navigator.pushNamedAndRemoveUntil(AppRoutes.assistant, (route) => false);
    }
  }

  static String _problemSentence(AppLocalizations l10n, AddressProblem problem) {
    switch (problem) {
      case AddressProblem.empty:
        return l10n.addressProblemEmpty;
      case AddressProblem.malformed:
        return l10n.addressProblemMalformed;
      case AddressProblem.unsupportedScheme:
        return l10n.addressProblemUnsupportedScheme;
      case AddressProblem.invalidPort:
        return l10n.addressProblemInvalidPort;
      case AddressProblem.cleartextRefused:
        return l10n.addressProblemCleartextRefused;
    }
  }
}

/// Refusal of a typed value: icon, colour and text, never colour alone.
class _ProblemNote extends StatelessWidget {
  const _ProblemNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.error_outline, size: 18, color: AppColors.danger),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.danger),
          ),
        ),
      ],
    );
  }
}

/// `PRD-MOBILE.md` §7, "Security — transport": an accepted cleartext address is
/// always accompanied by this warning.
class _CleartextWarning extends StatelessWidget {
  const _CleartextWarning({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadii.cardSmallAll,
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lock_open_outlined, color: AppColors.danger),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
