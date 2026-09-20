import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../l10n/app_localizations.dart';
import '../../net/backend_address.dart';
import '../../net/reachability.dart';
import '../../openapi/registry.dart';
import '../../theme/tokens.dart';
import '../connection_controller.dart';
import '../discovered_scope.dart';
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

  /// True while the user is re-entering an address after a successful connect,
  /// so the Success state is never a dead end.
  bool _editingAddress = false;

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
              child: _content(context, l10n, connection),
            ),
          ),
        ),
      ),
    );
  }

  /// UX spec, Pass 5 — the three states of the screen, in priority order.
  Widget _content(
    BuildContext context,
    AppLocalizations l10n,
    ConnectionController connection,
  ) {
    if (connection.isProbing) {
      return _buildLoading(context, l10n, connection);
    }
    final registry = connection.apiRegistry;
    if (!_editingAddress && registry != null && connection.canProceed) {
      return _buildSuccess(context, l10n, registry);
    }
    return _buildForm(context, l10n, connection);
  }

  /// UX spec, Pass 5 — Connection *Success*: the entity names the app derived
  /// and how many operations it can call. This is where discovery becomes
  /// visible to the operator (`FR-MA03`, Pass 6).
  Widget _buildSuccess(
    BuildContext context,
    AppLocalizations l10n,
    ApiRegistry registry,
  ) {
    final textTheme = Theme.of(context).textTheme;
    final names = registry.entities.map((entity) => entity.name).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.check_circle_outline, color: AppColors.success),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                l10n.connectSuccessHeadline,
                style: textTheme.titleMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        if (registry.operations.isEmpty)
          Text(
            l10n.connectSuccessNoOperations,
            style: textTheme.bodyMedium,
          )
        else ...[
          Text(
            l10n.connectSuccessEntities(joinEntityNames(l10n, names)),
            style: textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            l10n.connectSuccessOperations(registry.operations.length),
            style: textTheme.bodyMedium?.copyWith(color: AppColors.textMuted),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        FilledButton(
          onPressed: () => Navigator.of(
            context,
          ).pushNamedAndRemoveUntil(AppRoutes.assistant, (route) => false),
          child: Text(l10n.connectStart),
        ),
        const SizedBox(height: AppSpacing.sm),
        OutlinedButton(
          onPressed: () => setState(() => _editingAddress = true),
          child: Text(l10n.connectChangeAddress),
        ),
        const SizedBox(height: AppSpacing.xl),
        const ReachabilityIndicator(),
      ],
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
    // The result does not navigate away any more: a backend that answered now
    // has a Success state to show, and its scope is the point of discovery.
    final usable = await connection.connect(
      rawAddress: _addressController.text,
      token: _tokenController.text,
    );
    if (!mounted) return;
    setState(() => _editingAddress = !usable);
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
